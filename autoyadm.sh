#!/bin/bash

# This script reads tracked paths
# from a file and executes "yadm add"
# on all of them, then creates a timestamped
# commit and pushes the changes.
# Author: Daniel Fichtinger
# License: MIT

AYE="AutoYADM Error:"
AYM="AutoYADM:"
# TODO: ensure if we are tracking the encrypt list and archive,
# to run the encryption command to generate and updated encrypted archive

#### Encrypted Tracking

function get_encrypted_file {
  if [ -e "$XDG_CONFIG_HOME" ]; then
    if [ ! -f "$XDG_CONFIG_HOME/yadm/encrypt" ]; then
      mkdir -p "$XDG_CONFIG_HOME/yadm"
      touch "$XDG_CONFIG_HOME/yadm/encrypt"
    fi
    echo "$XDG_CONFIG_HOME/yadm/encrypt"
  elif [ -f "$HOME/.config/yadm/encrypt" ]; then
    echo "$HOME/.config/yadm/encrypt"
  else
    echo "$AYM Please move your encrypt file to ~/.config/yadm/encrypt."
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/encrypt"
  fi
}
# We check not to overwrite the user's env setting
if [ -z "$AUTOYADMENCRYPT" ] || ((!AUTOYADMENCRYPT)); then
  AUTOYADMENCRYPT=0
  echo "$AYM YADM encryption is disabled for cron compatibility, set AUTOYADMENCRYPT=1 when running ad hoc."
else
  yadm encrypt # prompts for password, should be wrapped with a --encrypt option to escape cron updates
fi

#### Normal Tracking

# Do not include encrypt in tracked list since it's built into YADM, just process encryption on each commit
# TODO: add a .autoyadmignore config, or logic that disables tracking of encrypt and archive files
function get_tracked_file {
  if [ -e "$XDG_CONFIG_HOME" ]; then
    if [ ! -f "$XDG_CONFIG_HOME/yadm/tracked" ]; then
      mkdir -p "$XDG_CONFIG_HOME/yadm"
      touch "$XDG_CONFIG_HOME/yadm/tracked"
    fi
    echo "$XDG_CONFIG_HOME/yadm/tracked"
  elif [ -f "$HOME/.config/yadm/tracked" ]; then
    echo "$HOME/.config/yadm/tracked"
  else
    echo "$AYM Please move your tracked file to ~/.config/yadm/tracked."
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tracked"
  fi
}

# We check not to overwrite the user's env setting
if [ -z "$AUTOYADMPUSH" ] || ((!AUTOYADMPUSH)); then
  AUTOYADMPUSH=0
  echo "$AYM Autopush is disabled."
fi

# Set hostname explicitly because it
# may not be present in this shell environment
if [ -z "$HOST" ]; then
  HOST="$(hostname)"
fi

# check if fd is installed,
# if so we prefer that. Setting this variable
# avoids needing to repeat the check on every
# fd/find invocation.
if command -v fd >/dev/null; then
  FD="true"
else
  FD="false"
fi

# First we read each path from "tracked"
(while read -r relpath; do
  path="$HOME/$relpath"
  # Execute yadm add on each real file
  # if the path points to a directory
  # This ensures symlinks are not added
  if [ -d "$path" ]; then
    if [ "$FD" == "true" ]; then
      # we prefer fd because it respects .ignore and .gitignore
      fd --no-require-git -t f . "$path" -X yadm add
    else
      find "$path" -type f -exec yadm add {} +
    fi
  # If just a file, we add directly
  elif [ -f "$path" ]; then
    yadm add "$path"
  # If neither file nor dir, something is very wrong!
  else
    echo "$AYE Target $path must be a directory or a file!"
    exit 1
  fi
done) <"$(get_tracked_file)"

# Now we also stage files already tracked by YADM
# that have been renamed or deleted; since the above
# loop will not stage them:

yadm add -u

yadmcommit() {
    # yadm status 
    if [[ -n $(yadm status --porcelain) ]]; then
        # -> make commit 
        yadm commit -m "AutoYADM commit: $(date +'%Y-%m-%d %H:%M:%S')"
    else
        echo "$AYM Nothing to commit."
    fi
}
autopush() {
    # -> check if auto-push enabled 
    if ((!AUTOYADMPUSH)); then
      echo "$AYM Pushing disabled, aborting..."
      exit 1
    fi
}
# -> proceed with push
sshagent() {
    # Check if the socket exists (may not be universal)
    if [[ -S "$SSH_AUTH_SOCK" ]]; then
        echo "SSH_AUTH_SOCK is set and socket exists: $SSH_AUTH_SOCK"
        echo "Checking agent forwarding"
        # -> check if key is being forwarded
        ssh-add -L 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "$AYM: SSH Agent is running and has forwarded keys, proceeding"
        else
            echo "$AYE SSH Agent is not running or has no forwarded keys"
            echo "Checking global git config for sshCommand as last resort"
            if [ -f "$HOME/.gitconfig" ]; then
                echo "$AYM Global .gitconfig exists."
                if grep -q  'sshCommand = ssh -i' "$HOME/.gitconfig"; then
                    echo "$AYM forward on push found in global config, attempting YADM push"
                else
                    echo "$AYE forward on push NOT found in global config. Aborting YADM push"
                    exit 1
                fi
            else
                echo "$AYE $HOME/.gitconfig does not exist! Aborting..."
                exit 1
            fi
        fi
    else
        echo "$AYE: SSH_AUTH_SOCK is set, but the socket is invalid or not found. Aborting push..."
        exit 1
    fi
}


yadmcommit # always commit updates
autopush   # check for autopushing to remote
sshagent   # verify ssh agent is available
yadm push  # push to remote