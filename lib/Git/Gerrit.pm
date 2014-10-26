use utf8;
use 5.010;
use strict;
use warnings;

package Git::Gerrit;
{
  $Git::Gerrit::VERSION = '0.002';
}
# ABSTRACT: Git extension to implement a Gerrit workflow

use Pod::Usage;
use Getopt::Long qw(:config auto_version auto_help);
use URI;
use URI::Escape;
use Gerrit::REST;

# Git-gerrit was converted from a script into a module following this:
# http://elliotlovesperl.com/2009/11/23/how-to-structure-perl-programs/
use Exporter 'import';
our @EXPORT_OK = qw/run/;

# The %Options hash is used to hold the command line options passed to
# all git-gerrit subcommands. The --verbose option is common to all of
# them. Each subcommand supports a specific set of options which are
# grokked by the get_options routine below.

my %Options = ( debug => 0 );
sub get_options {
    my (@opt_specs) = @_;
    return GetOptions(\%Options, 'debug', @opt_specs)
        or pod2usage(2);
}

# The cmd routine is used to invoke shell commands, usually git. It
# prints out the command before invoking it in debug operation.

sub cmd {
    my ($cmd) = @_;
    warn "CMD: $cmd\n" if $Options{debug};
    return system($cmd) == 0;
}

# The %Config hash holds the git-gerrit section configuration options.

my %Config;
sub grok_config {
    warn "CMD: git config --get-regexp \"^git-gerrit\\.\"\n"
        if $Options{debug};
    {
        open my $pipe, '-|', 'git config --get-regexp "^git-gerrit\."';
        while (<$pipe>) {
            if (/^git-gerrit\.(\S+)\s+(.*)/) {
                push @{$Config{$1}}, $2;
            } else {
                warn "Strange git-config output: $_";
            }
        }
    }

    # Override option defaults
    for my $opt (qw/verbose/) {
        $Options{$opt} = $Config{"default-$opt"}[-1]
            if exists $Config{"default-$opt"};
    }

    unless ($Config{baseurl} && $Config{project} && $Config{remote}) {
        warn <<EOF;

*** Please configure git-gerrit:

EOF

        warn <<EOF unless $Config{baseurl};
Run

    git config --global git-gerrit.baseurl "https://your.gerrit.domain"

to set your Gerrit server base URL. Omit --global if you only want to
configure it for this particular repository.

EOF

        warn <<EOF unless $Config{project};
Run

    git config git-gerrit.project "gerrit/project/name"

to set the Gerrit project your repository is associated with.

EOF

        warn <<EOF unless $Config{remote};
Run

    git config git-gerrit.remote "remote"

to set the git remote pointing to the Gerrit project.

EOF

        die;
    }

    $Config{baseurl}[-1] =~ s:/+$::; # trim trailing slashes from the baseurl

    push @{$Config{url}}, URI->new($Config{baseurl}[-1] . '/' . $Config{project}[-1]);

    $Config{baseurl}[-1] = URI->new($Config{baseurl}[-1]);

    chomp(my $gitdir = qx/git rev-parse --git-dir/);
    push @{$Config{gitdir}}, $gitdir;

    return;
}

sub config {
    my ($var) = @_;
    if (wantarray) {
        return exists $Config{$var} ? @{$Config{$var}}  : ();
    } else {
        return exists $Config{$var} ? $Config{$var}[-1] : undef;
    }
}

# The install_commit_msg_hook routine is invoked by a few of
# git-gerrit subcommands. It checks if the current repository already
# has a commit-msg hook installed. If not, it tries to download and
# install Gerrit's default commit-msg hook, which inserts Change-Ids
# in commits messages.

sub install_commit_msg_hook {
    require File::Spec;

    # Do nothing if it already exists
    my $commit_msg = File::Spec->catfile(scalar(config('gitdir')), 'hooks', 'commit-msg');
    return if -e $commit_msg;

    # Otherwise, check if we need to mkdir the hooks directory
    my $hooks_dir = File::Spec->catdir(scalar(config('gitdir')), 'hooks');
    mkdir $hooks_dir unless -e $hooks_dir;

    # Try to download and install the hook.
    eval { require LWP::Simple };
    if ($@) {
        warn "LWP: cannot install commit_msg hook because couldn't require LWP::Simple\n"
            if $Options{debug};
    } else {
        warn "LWP: install commit_msg hook\n" if $Options{debug};
        if (LWP::Simple::is_success(LWP::Simple::getstore(config('baseurl') . "/tools/hooks/commit-msg", $commit_msg))) {
            chmod 0755, $commit_msg;
        }
    }
}

# The credential_* routines below use the git-credential command to
# get and set credentials for git commands and also for Gerrit REST
# interactions.

sub credential_description {
    my $baseurl = config('baseurl');

    my $protocol = $baseurl->scheme;
    my $host     = $baseurl->host;
    my $path     = $baseurl->path;

    my $description = <<EOF;
protocol=$protocol
host=$host
path=$path
EOF

    if (my $username = config('username')) {
        $description .= <<EOF
username=$username
EOF
    }

    return $description;
}

sub get_credentials {
    # Create a temporary file to hold the credential description
    require File::Temp;
    my ($fh, $credfile) = File::Temp::tempfile(UNLINK => 1);
    $fh->print(credential_description(), "\n");
    $fh->print("\n");
    $fh->close;

    my %credentials;
    open my $pipe, '-|', "git credential fill <$credfile";
    while (<$pipe>) {
        chomp;
        $credentials{$1} = $2 if /^([^=]+)=(.*)/;
    }
    close $pipe;

    for my $key (qw/username password/) {
        exists $credentials{$key} or die "Couldn't get credential's $key\n";
    }

    return @credentials{qw/username password/};
}

sub set_credentials {
    my ($username, $password, $what) = @_;

    $what =~ /^(?:approve|reject)$/
        or die "set_credentials \$what argument ($what) must be either 'approve' or 'reject'\n";

    open my $git, '|-', "git credential $what";
    $git->print(credential_description(), "password=$password\n\n");
    $git->close;

    return;
}

# The get_message routine returns the message argument to the
# --message option. If the option is not present it invokes the git
# editor to let the user compose a message and returns it.

sub get_message {
    return $Options{message} if exists $Options{message};

    chomp(my $editor = qx/git var GIT_EDITOR/);

    die "Please, see 'git help var' to see how to set up an editor for git messages.\n"
        unless $editor;

    require File::Temp;
    my $tmp = File::Temp->new();

    require File::Slurp;
    File::Slurp::write_file($tmp->filename, <<'EOF');

# Please enter the review message for this change. Lines starting
# with '#' will be ignored, and an empty message aborts the review.
EOF

    cmd "$editor $tmp"
        or die "Aborting because I couldn't invoke '$editor $tmp'.\n";

    my $message = File::Slurp::read_file($tmp->filename);

    $message =~ s/(?<=\n)#.*?\n//gs; # remove all lines starting with '#'

    return $message;
}

# The gerrit routine keeps a cached Gerrit::REST object to which it
# relays REST calls.

sub gerrit {
    my $method = shift;

    state $gerrit;
    unless ($gerrit) {
        my ($username, $password) = get_credentials;
        $gerrit = Gerrit::REST->new(config('baseurl')->as_string, $username, $password);
        eval { $gerrit->GET("/projects/" . uri_escape_utf8(config('project'))) };
        if ($@) {
            set_credentials($username, $password, 'reject');
            die $@;
        } else {
            set_credentials($username, $password, 'approve');
        }
    }

    if ($Options{debug}) {
        my ($endpoint, @args) = @_;
        warn "GERRIT: $method $endpoint\n";
        if (@args) {
            require Data::Dumper;
            warn Data::Dumper::Dumper(@args);
        }
    }

    return $gerrit->$method(@_);
}

# The query_changes routine receives a list of strings to query the
# Gerrit server. It returns an array-ref containing a list of
# array-refs, each containing a list of change descriptions.

sub query_changes {
    my @queries = @_;

    return [] unless @queries;

    # If we're inside a git repository, restrict the query to the
    # current project's reviews.
    if (my $project = config('project')) {
        $project = uri_escape_utf8($project);
        @queries = map "q=project:$project+$_", @queries;
    }

    push @queries, "n=$Options{limit}" if $Options{limit};

    push @queries, "o=DETAILED_ACCOUNTS";

    my $changes = gerrit(GET => "/changes/?" . join('&', @queries));
    $changes = [$changes] if ref $changes->[0] eq 'HASH';

    return $changes;
}

# The get_change routine returns the description of a change
# identified by $id. An optional boolean second argument ($allrevs)
# tells if the change description should contain a description of all
# patchsets or just the current one.

sub get_change {
    my ($id, $allrevs) = @_;

    my $revs = $allrevs ? 'ALL_REVISIONS' : 'CURRENT_REVISION';
    return (gerrit(GET => "/changes/?q=change:$id&o=$revs"))[0][0];
}

# The current_branch routine returns the name of the current branch or
# 'HEAD' in a dettached head state.

sub current_branch {
    chomp(my $branch = qx/git rev-parse --abbrev-ref HEAD/);
    return $branch;
}

# The update_branch routine receives a local $branch name and updates
# it with the homonym branch in the Gerrit remote.

sub update_branch {
    my ($branch) = @_;

    my $remote = config('remote');
    cmd "git fetch $remote $branch:$branch";
}

# The following change_branch_* routines are used to create, list, and
# grok the local change-branches, i.e., the ones we create locally to
# map Gerrit's changes. Their names have a fixed format like this:
# "change/<upstream>/<id>. <Upstream> is the name of the local branch
# from which this change was derived. <Id> can be either a number,
# meaning the numeric id of a change already in Gerrit, or a
# topic-name, which was created by the "git-gerrit new <topic>"
# command.

sub change_branch_new {
    my ($upstream, $topic) = @_;
    die "The TOPIC cannot contain the slash character (/).\n"
        if $topic =~ m:/:;
    return "change/$upstream/$topic";
}

sub change_branch_lists {
    chomp(my @branches = map s/^\*?\s+//, qx/git branch --list 'change*'/);
    return @branches;
}

sub change_branch_info {
    my ($branch) = @_;
    if ($branch =~ m:^change/(?<upstream>.*)/(?<id>[^/]+):) {
        return ($+{upstream}, $+{id});
    }
    return;
}

# The current_change routine returns a list of two items: the upstream
# and the id of the change branch we're currently in. If we're not in
# a change branch, it returns the empty list.

sub current_change {
    return change_branch_info(current_branch);
}

# The current_change_id routine returns the id of the change branch
# we're currently in. If we're not in a change branch, it returns
# undef.

sub current_change_id {
    my ($branch, $id) = current_change;

    return $id;
}

############################################################
# MAIN

# Each git-gerrit subcommand is implemented by an anonymous routine
# associated with one or more names in the %Commands hash.

my %Commands;

$Commands{new} = sub {
    get_options('update');

    my $topic = shift @ARGV
        or pod2usage "new: Missing TOPIC.\n";

    $topic !~ m:/:
        or die "new: the topic name ($topic) should not contain slashes.\n";

    $topic =~ m:\D:
        or die "new: the topic name ($topic) should contain at least one non-digit character.\n";

    my $branch = shift @ARGV || current_branch;

    if (my ($upstream, $id) = change_branch_info($branch)) {
        die "new: You can't base a new change on a change branch ($branch).\n";
    }

    my $status = qx/git status --porcelain --untracked-files=no/;

    warn "Warning: git-status tells me that your working area is dirty:\n$status\n"
        if $status ne '';

    if ($Options{update}) {
        update_branch($branch)
            or die "new: Non-fast-forward pull. Please, merge or rebase your branch first.\n";
    }

    cmd "git checkout -b change/$branch/$topic $branch";

    install_commit_msg_hook;
};

$Commands{query} = sub {
    get_options(
        'verbose',
        'limit=i',
    );

    my (@names, @queries);
    foreach my $arg (@ARGV) {
        if ($arg =~ /(?<name>.*?)=(?<query>.*)/) {
            push @names,   $+{name};
            push @queries, $+{query};
        } else {
            push @names,   "QUERY";
            push @queries, $arg;
        }
    }

    my $changes = query_changes(@queries);

    # FIXME: consider using Text::Table for formatting
    my $format = "%-5s %-9s %-19s %-20s %-12s %-24s %s\n";
    for (my $i=0; $i < @$changes; ++$i) {
        print "\n[$names[$i]=$queries[$i]]\n";
        next unless @{$changes->[$i]};
        printf $format, 'ID', 'STATUS', 'UPDATED', 'PROJECT', 'BRANCH', 'OWNER', 'SUBJECT';
        foreach my $change (sort {$b->{updated} cmp $a->{updated}} @{$changes->[$i]}) {
            if ($Options{verbose}) {
                if (my $topic = gerrit(GET => "/changes/$change->{id}/topic")) {
                    $change->{branch} .= " ($topic)";
                }
            }
            printf $format,
                $change->{_number},
                $change->{status},
                substr($change->{updated}, 0, 19),
                $change->{project},
                $change->{branch},
                substr($change->{owner}{name}, 0, 24),
                $change->{subject};
        }
    }
    print "\n";
};

my %StandardQueries = (
    changes => [
        'Outgoing reviews=is:open+owner:self',
        'Incoming reviews=is:open+reviewer:self+-owner:self',
        'Recently closed=is:closed+owner:self+-age:1mon',
    ],
    drafts  => ['Drafts=is:draft'],
    watched => ['Watched changes=is:watched+status:open'],
    starred => ['Starred changes=is:starred'],
);
$Commands{my} = sub {
    if (@ARGV) {
        if (exists $StandardQueries{$ARGV[-1]}) {
            splice @ARGV, -1, 1, @{$StandardQueries{$ARGV[-1]}};
        } elsif ($ARGV[-1] =~ /^-/) {
            # By default we show 'My Changes'
            push @ARGV, @{$StandardQueries{changes}};
        } else {
            pod2usage "my: Invalid change specification: '$ARGV[-1]'";
        }
    } else {
        # By default we show 'My Changes'
        push @ARGV, @{$StandardQueries{changes}};
    }

    $Commands{query}();
};

$Commands{show} = sub {
    get_options('verbose');

    my $id = shift @ARGV || current_change_id()
        or pod2usage "show: Missing CHANGE.\n";

    my $change = gerrit(GET => "/changes/$id/detail");

    print <<EOF;
 Change-Num: $change->{_number}
  Change-Id: $change->{change_id}
    Subject: $change->{subject}
      Owner: $change->{owner}{name}
EOF

    if ($Options{verbose}) {
        if (my $topic = gerrit(GET => "/changes/$id/topic")) {
            $change->{topic} = $topic;
        }
    }

    for my $key (qw/project branch topic created updated status reviewed mergeable/) {
        printf "%12s %s\n", "\u$key:", $change->{$key}
            if exists $change->{$key};
    }

    for my $label (sort keys %{$change->{permited_labels}}) {
        for my $review (sort {$a->{name} cmp $b->{name}} @{$change->{labels}{$label}{all}}) {
            printf "%12s %-32s %+2d\n", "$label:", @{$review}{qw/name value/};
        }
    }
};

$Commands{config} = sub {
    cmd "git config --get-regexp \"^git-gerrit\\.\"";
};

$Commands{checkout} = sub {
    get_options();

    my $id = shift @ARGV || current_change_id()
        or pod2usage "checkout: Missing CHANGE.\n";

    my $change = get_change($id);

    my ($revision) = values %{$change->{revisions}};

    my ($url, $ref) = @{$revision->{fetch}{http}}{qw/url ref/};

    my $branch = "change/$change->{branch}/$change->{_number}";

    cmd "git fetch $url $ref:$branch"
        or die "Can't fetch $url\n";

    cmd "git checkout $branch";
};

$Commands{backout} = sub {
    get_options('keep');

    my $branch = current_branch;

    if (my ($upstream, $id) = change_branch_info($branch)) {
        if (cmd "git checkout $upstream") {
            if ($id =~ /^\d+$/ && ! $Options{keep}) {
                cmd "git branch -D $branch";
            } else {
                warn "Keeping $branch\n";
            }
        }
    } else {
        die "backout: You aren't in a change branch. I cannot back you out.\n";
    }
};

$Commands{push} = sub {
    get_options(
        'keep',
        'force',
        'rebase',
        'draft',
        'topic=s',
        'reviewer=s@',
        'cc=s@'
    );

    qx/git status --porcelain --untracked-files=no/ eq ''
        or die "push: Can't push change because git-status is dirty\n";

    my $branch = current_branch;

    my ($upstream, $id) = change_branch_info($branch)
        or die "push: You aren't in a change branch. I cannot push it.\n";

    my @commits = qx/git log --decorate=no --oneline HEAD ^$upstream/;
    if (@commits == 0) {
        die "push: no changes between $upstream and $branch. Pushing would be pointless.\n";
    } elsif (@commits > 1 && ! $Options{force}) {
        die <<EOF;
push: you have more than one commit that you are about to push.
      The outstanding commits are:

 @commits
      If this is really what you want to do, please try again with --force.
EOF
    }

    if ($Options{rebase} || $id =~ /\D/) {
        update_branch($upstream)
            or die "push: Non-fast-forward pull. Please, merge or rebase your branch first.\n";
        cmd "git rebase $upstream";
    }

    my $refspec = 'HEAD:refs/' . ($Options{draft} ? 'draft' : 'for') . "/$upstream";

    my @tags;
    if (my $topic = $Options{topic}) {
        push @tags, "topic=$topic";
    } elsif ($id =~ /\D/) {
        push @tags, "topic=$id";
    }
    if (my $reviewers = $Options{reviewer}) {
        push @tags, map("r=$_", split(/,/, join(',', @$reviewers)));
    }
    if (my $ccs = $Options{cc}) {
        push @tags, map("cc=$_", split(/,/, join(',', @$ccs)));
    }
    if (@tags) {
        $refspec .= '%';
        $refspec .= join(',', @tags);
    }

    my $remote = config('remote');
    cmd "git push $remote $refspec"
        or die "push: Error pushing change.\n";

    unless ($Options{keep}) {
        cmd("git checkout $upstream") and cmd("git branch -D $branch");
    }

    install_commit_msg_hook;
};

$Commands{reviewer} = sub {
    get_options(
        'add=s@',
        'confirm',
        'delete=s@',
    );

    my $id = shift @ARGV || current_change_id()
        or pod2usage "reviewer: Missing CHANGE.\n";

    # First try to make all deletions
    if (my $users = $Options{delete}) {
        foreach my $user (split(/,/, join(',', @$users))) {
            gerrit(DELETE => "/changes/$id/reviewers/$user");
        }
    }

    # Second try to make all additions
    if (my $users = $Options{add}) {
        my $confirm = $Options{confirm} ? 'true' : 'false';
        foreach my $user (split(/,/, join(',', @$users))) {
            gerrit(POST => "/changes/$id/reviewers/$user", { reviewer => $user, confirm => $confirm});
        }
    }

    # Finally, list current reviewers
    my @reviewers = gerrit(GET => "/changes/$id/reviewers");
    print "There are ", scalar(@reviewers), " reviewers currently:\n";
    foreach my $reviewer (@reviewers) {
        print "$reviewer->{name}\t$reviewer->{email}\t";
        foreach my $approval (sort keys $reviewer->{approvals}) {
            print "$approval:$reviewer->{approvals}{$approval}";
        } continue {
            print ", ";
        }
        print "\n";
    }
};

$Commands{review} = sub {
    get_options(
        'message=s',
        'keep',
    );

    my %review;

    if (my $message = get_message) {
        $review{message} = $message;
    }

    # Set all votes
    while (@ARGV && $ARGV[0] =~ /(?<label>.*)=(?<vote>.*)/) {
        shift @ARGV;
        $review{labels}{$+{label} || 'Code-Review'} = $+{vote};
        $+{vote} =~ /^[+-]?\d$/
            or pod2usage "review: Invalid vote ($+{vote}). It must be a single digit optionally prefixed by a [-+] sign.\n";
    }

    die "review: Invalid vote $ARGV[0].\n" if @ARGV > 1;

    die "review: You must specify a message or a vote to review.\n"
        unless keys %review;

    if (my $id = shift @ARGV) {
        gerrit(POST => "/changes/$id/revisions/current/review", \%review);
    } else {
        my $branch = current_branch;

        my ($upstream, $id) = change_branch_info($branch)
            or die "review: Missing CHANGE.\n";

        gerrit(POST => "/changes/$id/revisions/current/review", \%review);

        unless ($Options{keep}) {
            cmd("git checkout $upstream") and cmd("git branch -D $branch");
        }
    }
};

$Commands{abandon} = sub {
    get_options(
        'message=s',
        'keep',
    );

    my @args;

    if (my $message = get_message) {
        push @args, { message => $message };
    }

    if (my $id = shift @ARGV) {
        gerrit(POST => "/changes/$id/abandon", @args);
    } else {
        my $branch = current_branch;

        my ($upstream, $id) = change_branch_info($branch)
            or die "abandon: Missing CHANGE.\n";

        gerrit(POST => "/changes/$id/abandon", @args);

        unless ($Options{keep}) {
            cmd("git checkout $upstream") and cmd("git branch -D $branch");
        }
    }
};

$Commands{restore} = sub {
    get_options('message=s');

    my $id = shift @ARGV || current_change_id()
        or pod2usage "restore: Missing CHANGE.\n";

    my @args = ("/changes/$id/restore");

    if (my $message = get_message) {
        push @args, { message => $message };
    }

    gerrit(POST => @args);
};

$Commands{revert} = sub {
    get_options('message=s');

    my $id = shift @ARGV || current_change_id()
        or pod2usage "revert: Missing CHANGE.\n";

    my @args = ("/changes/$id/revert");

    if (my $message = get_message) {
        push @args, { message => $message };
    }

    gerrit(POST => @args);
};

$Commands{submit} = sub {
    get_options(
        'no-wait-for-merge',
        'keep',
    );

    my @args;
    push @args, { wait_for_merge => 1 } unless $Options{'no-wait-for-merge'};

    if (my $id = shift @ARGV) {
        gerrit(POST => "/changes/$id/submit", @args);
    } else {
        my $branch = current_branch;

        my ($upstream, $id) = change_branch_info($branch)
            or die "submit: Missing CHANGE.\n";

        gerrit(POST => "/changes/$id/submit", @args);

        unless ($Options{keep}) {
            cmd("git checkout $upstream") and cmd("git branch -D $branch");
        }
    }
};

$Commands{version} = sub {
    print "git-gerrit version $Git::Gerrit::VERSION\n";
    cmd "git version";
    my $version = eval { gerrit(GET => '/config/server/version') };
    $version //= "pre-2.7, since it doesn't support the Get Version REST Endpoint";
    print "Gerrit version $version\n";
};

# MAIN

sub run {
    my $command = shift @ARGV
        or die pod2usage "Missing command name.\n";

    exists $Commands{$command}
        or die pod2usage "Invalid command: $command.\n";

    grok_config;

    $Commands{$command}->();

    return 0;
}

1;

__END__

=pod

=head1 NAME

Git::Gerrit - Git extension to implement a Gerrit workflow

=head1 VERSION

version 0.002

=head1 SYNOPSIS

    use Git::Gerrit qw/run/;
    return 1 if caller;
    exit run();

=head1 DESCRIPTION

You're not supposed to use this module directly. :-)

It's used by the git-gerrit script which comes in the same CPAN
distribution. All the documentation that exists can be read via

    perldoc git-gerrit

=head1 AUTHOR

Gustavo L. de M. Chaves <gnustavo@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by CPqD <www.cpqd.com.br>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
