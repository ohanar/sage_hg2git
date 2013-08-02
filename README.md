### Files in repo

1. consolodate-repos.sh -- this is the script that converts the current
   mecurial based Sage tarballs into the git repository.

1. octopus.patch -- this is a patch to git that is required to run
   consolidate-repos.sh. For convience, the repository at
   github.com/ohanar/git.git contains this patch. This has been
   submitted upstream.

1. filter-branch.patch -- this is a patch that is applied during
   the runtime consolodate-repos.sh to a copy of the internal git
   script git-filter-branch. This is done so that use of Bash4
   associative arrays is possible -- alternatives dramatically
   increase the runtime of consolodate-repos.sh (to be on the
   order of days or weeks).

1. fast-export -- this directory includes a copy of hg-fast-export,
   which has been patched to not error out on some of the malformed
   commits that occur in Sage's repositories.
