#!/bin/bash
# consolidate-repos.sh
#
# Requires hg as well as the copy of git found at github.com/ohanar/git
#
# If notify-send is present, the script will a send a notification upon
# completion.
#
# Usage:
#
#   consolidate-repos.sh -i sagedir -o outdir -t tmpdir -m [merge commit message]
#
# Output:
#
# - A consolidated repo in outdir
#   + package_version.txt and VERSION.txt files will be put in there relevant places (but not committed)
#     * will also try to create the checksums.ini files
#   + If a repository is already there, then the consolidated repo will
#     be merged rather than created from scratch
# - tarballs for the source files in outdir/upstream/

set -e

CMD="${0##*/}"
CUR=$(readlink -f "$0")
export CUR=${CUR%/*}

die () {
    echo $@ 1>&2
    exit 1
}

usage () {
    echo "usage: $CMD -i sagedir -o outdir -t tmpdir -m [merge commit message]"
}

# parse command line options
while getopts "i:o:t:m:" opt ; do
    case $opt in
        i) SAGEDIR=$(readlink -f "$OPTARG") ;;
        o) OUTDIR=$(readlink -f "$OPTARG") ;;
        t) TMPDIR=$(readlink -f "$OPTARG") ;;
        m) MERGEMSG="$OPTARG" ;;
    esac
done
shift $((OPTIND-1))

# check for valid options
[ -n "$SAGEDIR" ] || die $(usage)
[ -n "$OUTDIR" ] || die $(usage)
[ -n "$TMPDIR" ] || TMPDIR="$(mktemp -d /tmp/consolidate-repos.XXXX)" &&
        MADETMP=yes && echo "Created directory $TMPDIR"
[ -n "$MERGEMSG" ] || MERGEMSG="Consolidate Sage's Repositories"

TARBALLS="$OUTDIR/upstream"

export SAGEDIR OUTDIR TMPDIR TARBALLS

mkdir -p "$TMPDIR" && cd "$TMPDIR" && rm -rf *

# initialize output repo
git init "$TMPDIR"/sage-repo && cd "$TMPDIR"/sage-repo

# move the base tarballs into $SAGE_TARBALLS
mkdir -p "$OUTDIR"/upstream
mkdir -p "$TMPDIR"/spkg
cp "$SAGEDIR"/spkg/base/*.tar* "$OUTDIR"/upstream

# get the SPKG repos converted to git and pull them into the consolidated repo
# also tarball the src/ directories of the SPKGs and put them into a upstream/ directory
mkdir -p "$TMPDIR"/spkg-git

# patch git filter-branch so that we can use bash's associative arrays across commits
pushd "$TMPDIR" > /dev/null
sed -e 's+/bin/sh+/usr/bin/env bash+g' -e 's+^. git-sh-setup$+. \$(git --exec-path)/git-sh-setup+' "$(git --exec-path)/git-filter-branch" > git-filter-branch
chmod +x git-filter-branch
git apply "$CUR"/filter-branch.patch
popd > /dev/null

process-spkg () {
    # figure out what the spkg is
    SPKGPATH=$1
    SPKG="${SPKGPATH#$SAGEDIR/spkg/*/}"
    SPKG="${SPKG%.spkg}"
    PKGNAME=$(sed -e 's/\([^-_]*\)[-_][0-9].*$/\1/' <<< "$SPKG")
    PKGVER=$(sed -e 's/^[-_]\+\(.*\)$/\1/' -e 's/[-_]/\./g' <<< "${SPKG#"$PKGNAME"}")
    PKGVER_UPSTREAM=$(sed -e 's/\.p[0-9][0-9]*$//' <<<"$PKGVER")
    TMP_REPO="$TMPDIR"/spkg-git/$PKGNAME
    HG_REPO="$TMPDIR"/spkg/$SPKG
    echo
    echo "*** Found SPKG: $PKGNAME version $PKGVER"
    tar x -p -C "$TMPDIR"/spkg -f "$SPKGPATH"

    if [ ! -d "${HG_REPO}/.hg" ]; then
        echo $PKGNAME no_repo >> $OUTDIR/failed_spkgs.txt
        rm -rf "$HG_REPO"
        return
    fi

    TAGS_SWITCH=''
    case $PKGNAME in
        sage_root)
            REPO=.
            BRANCH=base
        ;;
        sage)
            REPO=src
            BRANCH=library
            TAGS_SWITCH='--tag-name-filter cat'
        ;;
        sage_scripts)
            REPO=src/bin
            BRANCH=devel/bin
        ;;
        extcode)
            REPO=src/ext
            BRANCH=devel/ext
        ;;
        *)
            REPO=build/pkgs/$PKGNAME
            BRANCH=packages/$PKGNAME

            if tar --test-label < "$SPKGPATH" 2>/dev/null; then
                TAROPTS=
                TAREXT=.tar
            elif gzip -t "$SPKGPATH" 2>/dev/null; then
                TAROPTS=z
                TAREXT=.tar.gz
            else # assume everything else is bzip2
                TAROPTS=j
                TAREXT=.tar.bz2
            fi

            NEW_TARBALL="$TARBALLS"/$PKGNAME-${PKGVER_UPSTREAM}.new${TAREXT}
            TARBALL="$TARBALLS"/$PKGNAME-${PKGVER_UPSTREAM}${TAREXT}

            if [ ! -d "$HG_REPO/src" ]; then
                echo $PKGNAME no_src >> $OUTDIR/failed_spkgs.txt
                rm -rf "$HG_REPO"
                return
            fi

            pushd "$HG_REPO" > /dev/null
            mv -T src $PKGNAME-$PKGVER_UPSTREAM
            if [ -f "$TARBALL" ]; then
                tar c -${TAROPTS}f "$NEW_TARBALL" $PKGNAME-$PKGVER_UPSTREAM
            else
                tar c -${TAROPTS}f "$TARBALL" $PKGNAME-$PKGVER_UPSTREAM
            fi
            rm -rf $PKGNAME-$PKGVER_UPSTREAM
            popd > /dev/null
        ;;
    esac

    # convert the SPKG's hg repo to git
    git init --bare "$TMP_REPO"
    pushd "$TMP_REPO" > /dev/null
    "$CUR"/fast-export/hg-fast-export.sh -r "$HG_REPO" -M master || {
        echo $PKGNAME bad_repo >> $OUTDIR/failed_spkgs.txt;
        rm -rf "$HG_REPO";
        return;
    }

    rm -rf "$HG_REPO"

    # rewrite paths
    # hacked into git-filter-branch so that we can use a bash array across
    # commits (bash does not support exporting arrays)
    export REPO
    "$TMPDIR"/git-filter-branch -f -d "$TMPDIR/filter-branch/$SPKG" --prune-empty --index-filter '' $TAGS_SWITCH master
    popd > /dev/null

    if [ -n "$TAGS_SWITCH" ]; then
        TAGS_SWITCH=''
    else
        TAGS_SWITCH='-n'
    fi
    # pull it into the consolidated repo
    git fetch $TAGS_SWITCH "$TMP_REPO" master:$BRANCH &&
        rm -rf "$TMP_REPO"

    # save the package version for later
    echo "$PKGVER" > "$TMP_REPO".txt
}
export -f process-spkg

for SPKGPATH in "$SAGEDIR"/spkg/*/*.spkg ; do
    process-spkg "$SPKGPATH"
done

REMOTE_NAME=$(uuidgen)
git init $OUTDIR
cd $OUTDIR

if git branch | grep master; then
    git checkout master
fi

git remote add --fetch $REMOTE_NAME "$TMPDIR"/sage-repo
if ! git rev-parse HEAD &>/dev/null; then
    git merge $REMOTE_NAME/base
fi

BRANCHES="$(git branch --remote --no-merged | GREP_OPTIONS= grep "^  $REMOTE_NAME" | tr '\n' ' ')"
git merge -m "$MERGEMSG" $BRANCHES

git remote rm $REMOTE_NAME

if ! git branch | grep build_system; then
    git branch build_system
fi
git checkout build_system

# Optimize the repo
git gc --aggressive --prune=0

# copy package-version.txt files into outdir to track package \.p[0-9]+ versions
# (i.e. local revisions)
for BRANCH in $BRANCHES; do
    case $BRANCH in
        $REMOTE_NAME/packages/*)
            PKGNAME=${BRANCH#$REMOTE_NAME/packages/}
            mv -T "$TMPDIR"/spkg-git/${PKGNAME}.txt build/pkgs/$PKGNAME/package-version.txt
            ;;
    esac
done

cp "$SAGEDIR/VERSION.txt" .
if [ -f src/bin/sage-fix-pkg-checksums ]; then
    ./sage -sh -c 'sage-fix-pkg-checksums'
fi

# Clean up $TMPDIR
[ -z $MADETMP ] || rm -rf "$TMPDIR"

if command -v notify-send; then
    notify-send "$CMD: finished parsing SPKGs"
fi
