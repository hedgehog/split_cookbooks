#!/usr/bin/env bash
# script to produce archives

# References:
# - http://systemoverlord.com/blog/2011/07/16/automatically-creating-archives-git-tags

# Debug mode
DEBUG=1

# Where where the repository folder resides
REPO_DIR=$1
# What is the repository name
REPO=$2
# Where to put tag archives
ARCHIVE_DIR=$3

# What dir to place files under in the git archive
PREFIX=$4

echo ${REPO_DIR}
echo 'Processing...'
pushd ${REPO_DIR}
  BRANCH=`echo -n $(git symbolic-ref HEAD 2>/dev/null | awk -F/ {'print $NF'})`

  # When to allow archiving (regex)
  #ALLOW_ARCHIVE="^(drupal|moodle)"
  ALLOW_ARCHIVE="(\*)"

  #### NO CONFIG BELOW ####
  # Check if this repo can be archived
  #  if [[ ! "$REPO_DIR" =~ $ALLOW_ARCHIVE ]] ; then
  #      [[ $DEBUG ]] && echo "Archiving for this repository is disabled."
  #      exit 0
  #  fi

  # Get repo name
  ARCHIVE_DIR="${ARCHIVE_DIR}/${REPO}"

  while read rev ref ; do
      if [[ ! "$ref" =~ ^refs/tags ]] ; then
          [[ $DEBUG ]] && echo "Not a tag reference..."
          continue
      fi
      if [[ ! "$ref" =~ ^refs/tags/qa- ]] ; then
          [[ $DEBUG ]] && echo "Not a qa- tag..."
          continue
      fi

      # Get tag name
      tag=${ref##*/}

      # Check if tag contains alpha, beta, or release:
      # if [[ ! $tag =~ (alpha|beta|release) ]] ; then
      #     [[ $DEBUG ]] && echo "Not alpha/beta/release"
      #     continue
      # fi

      # Ensure directory exists
      mkdir -p ${ARCHIVE_DIR}

      # Get repo base name
      REPO_BASE=${REPO##*/}

      # Make zip archive
      #      if [[ ! -e "${ARCHIVE_DIR}/${tag}.zip" ]] ; then
      #        [[ $DEBUG ]] && echo git archive --format=zip --prefix=${REPO_BASE}/ -o "${ARCHIVE_DIR}/${tag}.zip" $ref
      #        git archive --format=zip --prefix=${REPO_BASE}/ -o "${ARCHIVE_DIR}/${tag}.zip" $ref
      #      fi
      # Make tar.gz archive
      #      if [[ ! -e "${ARCHIVE_DIR}/${tag}.tar.gz" ]] ; then
      #        [[ $DEBUG ]] && echo git archive --format=tar.gz --prefix=${REPO_BASE}/ -o "${ARCHIVE_DIR}/${tag}.tar.gz" $ref
      #        git archive --format=tar.gz --prefix=${REPO_BASE}/ -o "${ARCHIVE_DIR}/${tag}.tar.gz" $ref
      #      fi
      # Make tar.xz archive
      if [[ ! -e "${ARCHIVE_DIR}/${tag}.tar.xz" ]] ; then
        echo ${REPO_BASE}
        [[ $DEBUG ]] && echo git archive --format=tar --prefix=${PREFIX}/ -o "${ARCHIVE_DIR}/${tag}.tar" $ref
        git archive --format=tar --prefix=${PREFIX}/ -o "${ARCHIVE_DIR}/${tag}.tar" $ref
        xz -9 --extreme --suffix=.xz "${ARCHIVE_DIR}/${tag}.tar"
      fi
  done < <(git show-ref)
popd