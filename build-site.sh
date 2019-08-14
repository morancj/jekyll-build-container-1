#!/bin/bash
#
# This script is run inside the Docker container to build the static web site using Jekyll.

# Variables
# Override $HOME to point at the volume-mounted directory. This is needed
# because Bundle writes to a .bundle directory inside the user's home
# directory.
export HOME=/srv/source
#
# Define where we are looking for the multi-site manifest file.
MANIFEST_FILE=/srv/source/manifest.json

# Define some colours
# (https://stackoverflow.com/questions/5947742/how-to-change-the-output-color-of-echo-in-linux)
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
get_tag_for_latest() {
    LATEST_ALIAS=""
    # From https://stackoverflow.com/a/41830007/1233830
    REPOSITORY="linaroits/jekyllsitebuild"
    TARGET_TAG="latest"
    # Check that we have Internet access - bail quickly if we don't.
    # We don't care about what curl returns so throw it away.
    _=$(curl -s "https://auth.docker.io") || return $?
    # Get authorization token.
    TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REPOSITORY:pull" | jq -r .token) || return $?
    # Find all tags.
    ALL_TAGS=$(curl -s -H "Authorization: Bearer $TOKEN" https://index.docker.io/v2/$REPOSITORY/tags/list | jq -r .tags[]) || return $?
    # Get image digest for target/
    TARGET_DIGEST=$(curl -s -D - -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "https://index.docker.io/v2/$REPOSITORY/manifests/$TARGET_TAG" | grep Docker-Content-Digest | cut -d ' ' -f 2) || return $?
    # For each tag ...
    for tag in "${ALL_TAGS[@]}"; do
        # get image digest
        digest=$(curl -s -D - -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "https://index.docker.io/v2/$REPOSITORY/manifests/$tag" | grep Docker-Content-Digest | cut -d ' ' -f 2) || return $?
        # and check digest.
        if [ "$TARGET_DIGEST" = "$digest" ] && [ "$tag" != "$TARGET_TAG" ]; then
            LATEST_ALIAS="$tag"
        fi
    done
}

# If possible, show which container version this is
check_container_version() {
    if [ -n "${BAMBOO_BUILD}" ]; then
        echo "Container built by bamboo.linaro.org: ${BAMBOO_BUILD}"
        get_tag_for_latest || LATEST_ALIAS=""
        if [ -n "$LATEST_ALIAS" ] && [ "$LATEST_ALIAS" != "${BAMBOO_BUILD}" ]; then
            echo "******************************************************************"
            echo "WARNING! This does not appear to be the latest Docker image:"
            echo "         $LATEST_ALIAS"
            echo "If the build fails, please 'docker pull linaroits/jekyllsitebuild'"
            echo "and try again."
            echo "******************************************************************"
        fi
    fi
}

# Check we've got defined vars
check_environment_variables() {
    if [ -z "$JEKYLL_ENV" ]; then
        echo -e "${RED}JEKYLL_ENV needs to be set${NC}"
        exit 1
    fi
    if [ "$JEKYLL_ENV" != "staging" ] && [ "$JEKYLL_ENV" != "production" ]; then
        echo -e "${RED}JEKYLL_ENV must be set to 'staging' or 'production'${NC}"
        exit 1
    fi
}

# Check that we've got a source dir. We now always build the site inside the
# source directory.
check_source_dir() {
    if [ ! -d "/srv/source" ]; then
        echo -e "${RED}Cannot find source directory${NC}"
        exit 1
    fi
    # Initialise the source location. This will get changed if we have a
    # multi-repo site to build.
    SOURCE_DIR="/srv/source"
}

get_repo_url() {
    if [ ! -f "$1" ]; then
        # No file to get the URL from so quietly fail back to the caller
        REPOURL=""
        return
    fi
    REPOURL=$(awk '/remote "origin"/ {f=1; next} f==1&& /url =/ {f=0; print $3}' "$1")
    # This is likely to be something like git@github.com:96boards/documentation.git
    # but we need something like https://github.com/96boards/documentation.git so
    # munge things around into the correct format.
    #
    # Start by seeing if the URL starts with https:. Do this by splitting on the colon
    # as that then helps us if we need to munge anyway.
    IFS=':' read -ra SPLIT <<< "$REPOURL"
    #
    # If no colon, we've fowled up somewhere.
    if [ "${#SPLIT[@]}" != "2" ]; then
        echo -e "${RED}Failed to retrieve Git URL from $1${NC}"
        exit 1
    fi
    if [ "${SPLIT[0]}" == "https" ]; then
        return
    fi
    REPOURL="https://github.com/${SPLIT[1]}"
}

# If /srv/source contains the files for the repository specified
# in $2, copy the files to the path specified in $3.
check_srv_source() {
    get_repo_url /srv/source/.git/config
    if [ "$REPOURL" != "$2" ]; then
        # Not this repo
        return 1
    fi
    echo "Copying repo files into $3"
    # Build the destination path and make sure it exists. Note that
    # the paths read from the manifest file always start with /
    dest_path="/srv/source/merged_sources$3"
    mkdir -p "$dest_path" || exit 1
    rsync -r "${RSYNC_EXCLUDE[@]}" /srv/source/ "$dest_path" || exit 1
}

# If /srv/<varname> (where varname is $1) exists and matches the repository
# specified in $2, copy the files to the path specified in $3.
check_srv_varname() {
    if [ -d "/srv/$1" ]; then
        get_repo_url "/srv/$1/.git/config"
        if [ "$REPOURL" != "$2" ]; then
            # Not this repo
            return 1
        fi
        echo "Copying $1 repo files into $3"
        # Build the destination path and make sure it exists. Note that
        # the paths read from the manifest file always start with /
        dest_path="/srv/source/merged_sources$3"
        mkdir -p "$dest_path" || exit 1
        rsync -r "${RSYNC_EXCLUDE[@]}" "/srv/$1"/ "$dest_path" || exit 1
    else
        # Show that this failed
        return 1
    fi
}

# Clone the repo specified by $2 and copy the files into $3. We can't
# clone directly into $3 because it might not be empty and "git clone"
# refuses to clone into a non-empty directory.
clone_missing_repo() {
    temp_dir=$(mktemp -d)
    echo "Cloning $2"
    git clone --quiet "$2" "$temp_dir" || exit 1
    echo "Copying repo files into $3"
    dest_path="/srv/source/merged_sources$3"
    mkdir -p "$dest_path" || exit 1
    cp -r "$temp_dir"/* "$dest_path" || exit 1
    rm -rf "$temp_dir" || exit 1
}

process_single_repo() {
    # This is passed the three values from the CSV file, namely:
    # Environment variable name
    #    If this exists on the host, the calling script takes the value
    #    as a path to the source directory and volume-maps it onto
    #    /srv/<varname>
    # GitHub repo URL
    #    Note that we always use the https:// version so that we can
    #    clone without needing SSH keys. We use this to compare with
    #    the path in .git/config to match repos.
    # Directory path
    #    Where under /srv/source/merged_sources these files need to be
    #    copied to.
    #
    # If this repo maps onto the repo in /srv/source, copy the files.
    #
    # If /srv/<varname> exists, copy the files.
    #
    # Otherwise, clone the repo into the desired directory.
    #
    # Made slightly more complicated by the fact that Bash functions
    # can't return values other than an exit code. Anything else
    # needs to be returned in variables.

    echo -e "${GREEN}$1:${NC} $2"

    check_srv_source "$1" "$2" "$3" || \
    check_srv_varname "$1" "$2" "$3" || \
    clone_missing_repo "$1" "$2" "$3"
}

process_repos() {
    # Experimenting with NOT cleaning out the merged_sources directory.
    # The reason why is because 96Boards does a lot of image resizing
    # and those images are stored under the "assets" folder in the source
    # directory that Jekyll is looking at, i.e. the merged_sources directory.
    # Clearing out the merged_sources directory on every build makes every
    # subsequent build just as slow as before because all of the images
    # have to be rebuilt. NOT clearing out the merged_sources directory
    # allows the previous cache to be re-used.
    #
    # # If we already have a "merged_sources" directory, clean it out.
    # if [ -d "/srv/source/merged_sources" ]; then
    #     rm -r /srv/source/merged_sources
    # fi

    # Get the possible built site directory names from the manifest and
    # build a rsync exclusion "command". Use an array so that the elements
    # get correctly expanded when rsync is called.
    declare -a RSYNC_EXCLUDE
    # Don't copy anything dotted (e.g. .git, .asset-cache).
    # Don't copy any scripts.
    RSYNC_EXCLUDE=(--exclude ".*" --exclude "*.sh")
    RSYNC_EXCLUDE+=(--exclude "merged_sources" --exclude "CODEOWNERS" --exclude "manifest.json")
    dirs=$(jq -r '.site_dirs | .[]' < $MANIFEST_FILE) || exit $?
    for d in $dirs
    do
        RSYNC_EXCLUDE+=(--exclude "$d")
    done

    # Iterate through the manifest and process each repo in turn.
    declare -A repo_array
    repo_count=$(jq -r '.repos | length' < $MANIFEST_FILE) || exit $?
    for ((i=0; i < repo_count; i++))
    do
        # Go through some funky steps to read in the repo definition
        # into an array that we can then pass to the function.
        #
        # We save the output from jq first in case it barfs so that we can exit then.
        PARSED=$(jq -r ".repos | .[$i] | to_entries | .[] | .key + \"=\" + .value" $MANIFEST_FILE) || exit $?
        while IFS='=' read -r key value; do
            repo_array["$key"]="$value"
        done <<< "$PARSED"
        process_single_repo "${repo_array[tag]}" "${repo_array[url]}" "${repo_array[dir]}"
    done
}

# Check if this is a multi-repo site and take the appropriate action.
check_multi_repo() {
    # A multi-repo site is determined by whether or not there is a manifest
    # file in /srv/source.
    if [ -f "$MANIFEST_FILE" ]; then
        echo "Multi-repo site detected; processing the required repositories ..."
        process_repos
        SOURCE_DIR="/srv/source/merged_sources"
        JEKYLL_EXTRA="-s $SOURCE_DIR --layouts $SOURCE_DIR/_layouts"
    else
        echo "Single-repo site - proceeding with normal processing."
        JEKYLL_EXTRA=""
    fi
}

# Check that we've got a Gemfile in the source directory.
check_Gemfile() {
    if [ ! -f "$SOURCE_DIR/Gemfile" ]; then
        echo -e "${RED}Cannot find Gemfile in source directory${NC}"
        exit 1
    fi
}

# If there is a Gemfile.lock, delete it because it may reference child-gems
# that the build container doesn't have installed.
remove_Gem_lockfile() {
    if [ -f "Gemfile.lock" ]; then
        rm Gemfile.lock
    fi
}

# Change to the source directory. Note that we always change to *this* directory,
# even if we are building a multi-repo site, because a multi-repo site tells
# Jekyll explicitly where the source directory is, and we want the destination
# directory to be relative to the *current* directory.
set_working_directory() {
    cd "/srv/source" || exit
}

jekyll_commands_common() {
    # Need to tell bundler where the Gemfile is located in case we're
    # building a multi-repo site.
    BUNDLE_GEMFILE="$SOURCE_DIR/Gemfile" \
    bundle exec jekyll \
    "$JEKYLL_ACTION" \
    $JEKYLL_EXTRA \
    --config "$SOURCE_DIR/_config.yml,$SOURCE_DIR/_config-$JEKYLL_ENV.yml" \
    "$@"
}

# Validate the source material before trying to build the site
jekyll_doctor() {
    echo -e "${YELLOW}Validating source files${NC}"
    JEKYLL_ACTION="doctor" \
    jekyll_commands_common ; \
    EXIT_CODE=$?
    # Return a non-zero code in the event of an error so we then
    # don't go any further.
    if [ "$EXIT_CODE" -ne 0 ]; then
        exit "$EXIT_CODE"
    fi
}

# Build the site
# Default to building; allows JEKYLL_ACTION override to build and serve.
jekyll_build() {
    echo -e "${YELLOW}Building site${NC}"
    if [ -z "$JEKYLL_ACTION" ]; then
        JEKYLL_ACTION="build"
    fi
    if [ "$JEKYLL_ACTION" == "serve" ]; then
        HOSTING_OPTIONS="--host 0.0.0.0"
    else
        HOSTING_OPTIONS=""
    fi
    jekyll_commands_common \
    $HOSTING_OPTIONS \
    --strict_front_matter \
    --trace \
    "$@" \
    JEKYLL_ENV="$JEKYLL_ENV"
}

# Execution
check_container_version
check_environment_variables
check_source_dir
check_multi_repo
set_working_directory
check_Gemfile
remove_Gem_lockfile
jekyll_doctor
jekyll_build "$@"
