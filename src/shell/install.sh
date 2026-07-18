#!/bin/sh
# Copyright logship LLC 2024
# This script installs the logship agent, frontend, and database
set -eu

bold=""
underline=""
standout=""
normal=""
black=""
red=""
green=""
yellow=""
blue=""
magenta=""
cyan=""
white=""
if test -t 1 && [ "${NO_COLOR:-}" != "1" ]; then
  ncolors=$(tput colors)
  if test -n "$ncolors" && test "$ncolors" -ge 8; then
    bold="$(tput bold)"
    underline="$(tput smul)"
    standout="$(tput smso)"
    normal="$(tput sgr0)"
    black="$(tput setaf 0)"
    red="$(tput setaf 1)"
    green="$(tput setaf 2)"
    yellow="$(tput setaf 3)"
    blue="$(tput setaf 4)"
    magenta="$(tput setaf 5)"
    cyan="$(tput setaf 6)"
    white="$(tput setaf 7)"
  fi
fi

usage() {
  cat <<EOF
${bold}Usage:${normal} ${blue}${CMD:=${0##*/}}${normal} ${cyan}[OPTIONS]${normal}
  e.g. ${CMD:=${0##*/}} -adf ${green}# logship installer${normal}

  Providing no download/install arguments will install the database, frontend, and agent.
  Run in a terminal to configure interactively, or pass ${cyan}-y${normal} (with options) for an unattended install.

${bold}Options:${normal}
  ${cyan}-a${normal}, ${cyan}--agent${normal}
          Download and configure the logship agent
  ${cyan}-d${normal}, ${cyan}--database${normal}
          Download and configure the logship database
  ${cyan}-f${normal}, ${cyan}--frontend${normal}
          Download and configure the logship frontend

      ${cyan}--hostname${normal}
          [default: localhost] Set the backend hostname. Accepts a full URL;
          an ${cyan}https://${normal} host is used as-is (TLS on 443).
      ${cyan}--account${normal}
          [default: 00000000-0000-0000-0000-000000000000] Account GUID the agent ships to
      ${cyan}--registration-token${normal}
          Agent registration token used to authenticate to the backend
      ${cyan}--database-port${normal}
          [default: 5000] Set the database's listen port
      ${cyan}--frontend-port${normal}
          [default: 8000] Set the frontend's listen port
      ${cyan}--no-install${normal}
          Disable installation (systemd, or PATH for logsh)
      ${cyan}--overwrite${normal}
          Overwrite existing configurations
      ${cyan}--path${normal}
          [default: /opt/logship] Set install directory
      ${cyan}--data-root${normal}
          [default: /logship] Set the logship data directory
      ${cyan}--preview${normal}
          Download pre-release versions.

      ${cyan}--no-color${normal}
          Disable colorful output
  ${cyan}-y${normal}, ${cyan}--yes${normal}, ${cyan}--non-interactive${normal}
          Skip interactive prompts and install unattended
  ${cyan}-v${normal}, ${cyan}--verbose${normal}
          Enable verbose output
  ${cyan}-h${normal}, ${cyan}--help${normal}
          Print this help message

EOF
}

info() {
  printf "${bold}${blue}%s:${normal} %s\n" "${CMD:=${0##*/}}" "$1"
}

verbose() {
  if [ "$opt_verbose" = 'true' ]; then
    printf "${bold}${yellow}%s:${normal} %s\n" "${CMD:=${0##*/}}" "$1"
  fi
}

err() {
  printf "${bold}${red}%s:${normal}${red} %s${normal}\n" "${CMD:=${0##*/}}" "$1" >&2
  exit 1
}

# Detect architecture
if [ "$(uname -m)" = "x86_64" ]; then
  architecture="x64"
elif [ "$(uname -m)" = "aarch64" ]; then
  architecture="arm64"
else
  err "Unsupported architecture: $(uname -m)"
fi

# Detect operating system
if [ "$(uname -s)" = "Darwin" ]; then
  operating_system="osx"
elif [ "$(uname -s)" = "Linux" ]; then
  operating_system="linux"
else
  err "Unsupported operating system: $(uname -s)"
fi

verbose_ship() {
  # Was this a waste of time? Maybe
  if [ "$opt_verbose" = 'true' ]; then
    printf "         %s*%s    _______                                                     \n" "$bold$white" "$normal"
    printf "           %s*%s  |   %s==%s|                                            %s_%s        \n" "$bold$white" "$normal" "$bold" "$normal" "$bold" "$normal"
    printf "           ||_|     |%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s|%s        \n" "$blue" "$green" "$blue" "$red" "$white" "$green" "$white" "$red" "$white" "$blue" "$magenta" "$normal$bold" "$normal"
    printf "          _||_|     |%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s[||]%s|%s___     \n" "$red" "$white" "$blue" "$magenta" "$white" "$green" "$green" "$white" "$white" "$red" "$blue" "$normal$bold" "$normal"
    printf "         |......................................................o.../     \n"
    printf "         \........................................................./      \n"
    printf "%s_,_,~_,~')_,~')_,~')_,~')_,~')_,~')_~')_,~')_~')_,~')_,~')_,~')_,~')_,~')%s\n\n" "$bold$blue" "$normal"
  fi
}

invalid_arg() {
  printf >&2 "${bold}${red}%s:${normal}  %s: '${yellow}%s${normal}'\n" "${CMD:=${0##*/}}" "$1" "$2"
  usage
  exit 2
}
check() { { [ "$1" != "$EOL" ] && [ "$1" != '--' ]; } || exit2 "missing argument" "$2"; } # avoid infinite loop

is_valid_port() {
  printf '%s' "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 0 ] && [ "$1" -le 65535 ]
}

check_port() {
  is_valid_port "$1" || err "Argument value \"$1\" is not a valid port."
}

# Interactive prompts read from /dev/tty so they work under "curl ... | sh",
# where stdin is the script itself rather than the terminal.
is_interactive() {
  [ "$opt_yes" != 'true' ] && [ -t 1 ] && [ -r /dev/tty ]
}

ask() {
  # ask "prompt" "default" -> echoes the answer.
  # Pre-fills the default as editable text where the shell supports it (bash),
  # otherwise shows it as a [hint]. Empty input always falls back to the default.
  if [ -n "${BASH_VERSION:-}" ]; then
    printf "${bold}${blue}%s${normal}: " "$1" >/dev/tty
    # shellcheck disable=SC3045 # read -e/-i is guarded behind the bash check above
    read -r -e -i "$2" _answer </dev/tty
  else
    printf "${bold}${blue}%s${normal} [${cyan}%s${normal}]: " "$1" "$2" >/dev/tty
    read -r _answer </dev/tty
  fi
  [ -z "$_answer" ] && _answer="$2"
  printf '%s' "$_answer"
}

ask_yn() {
  # ask_yn "prompt" "Y|N" -> returns 0 for yes, 1 for no
  case "$2" in [Yy]*) _hint='Y/n' ;; *) _hint='y/N' ;; esac
  printf "${bold}${blue}%s${normal} [${cyan}%s${normal}]: " "$1" "$_hint" >/dev/tty
  read -r _answer </dev/tty
  [ -z "$_answer" ] && _answer="$2"
  case "$_answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

ask_secret() {
  # ask_secret "prompt" "default" -> reads a secret without echoing it.
  # The default is never displayed (it may be sensitive); empty input keeps it.
  printf "${bold}${blue}%s${normal}: " "$1" >/dev/tty
  # Turn off terminal echo around the read so the value never renders.
  _stty_saved=$(stty -g </dev/tty 2>/dev/null) || _stty_saved=''
  [ -n "$_stty_saved" ] && stty -echo </dev/tty 2>/dev/null
  read -r _answer </dev/tty
  [ -n "$_stty_saved" ] && stty "$_stty_saved" </dev/tty 2>/dev/null
  printf '\n' >/dev/tty # echo was off, so emit the newline the user's Enter didn't
  [ -z "$_answer" ] && _answer="$2"
  printf '%s' "$_answer"
}

was_set() {
  # was_set <option-name> -> true if that option was passed on the command line.
  case " $explicit_opts " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

ask_port() {
  # ask_port "prompt" "default" -> echoes a valid port, re-prompting on error
  while true; do
    _port="$(ask "$1" "$2")"
    if is_valid_port "$_port"; then
      printf '%s' "$_port"
      return 0
    fi
    printf "${bold}${red}Invalid port: '%s'. Enter a number between 0 and 65535.${normal}\n" "$_port" >/dev/tty
  done
}

clean_hostname() {
  # Strip a URL scheme and any /path, leaving a bare host for display messages.
  # e.g. "https://backend.logship.io/foo" -> "backend.logship.io"
  _host="${1#http://}"
  _host="${_host#https://}"
  _host="${_host%%/*}"
  printf '%s' "$_host"
}

backend_url() {
  # backend_url "hostname" "port" -> full URL the agent/frontend use to reach
  # the backend. Honors an http(s):// scheme in the hostname: an https host
  # (or one with an explicit :port) is used as-is; a bare/http host gets the
  # configured port appended. So "https://backend.logship.io" stays TLS on 443,
  # while "localhost" becomes "http://localhost:$port".
  _scheme='http'
  _h="$1"
  case "$_h" in
  https://*) _scheme='https' && _h="${_h#https://}" ;;
  http://*) _h="${_h#http://}" ;;
  esac
  _h="${_h%%/*}" # strip any path
  case "$_h" in
  *:*) printf '%s://%s' "$_scheme" "$_h" ;;            # host already has :port
  *) if [ "$_scheme" = 'https' ]; then
    printf 'https://%s' "$_h"                          # https: assume 443
  else
    printf 'http://%s:%s' "$_h" "$2"                   # http/bare: append port
  fi ;;
  esac
}

is_valid_guid() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

check_guid() {
  is_valid_guid "$1" || err "Argument value \"$1\" is not a valid account GUID (expected 8-4-4-4-12 hex)."
}

ask_guid() {
  # ask_guid "prompt" "default" -> echoes a valid GUID, re-prompting on error
  while true; do
    _guid="$(ask "$1" "$2")"
    if is_valid_guid "$_guid"; then
      printf '%s' "$_guid"
      return 0
    fi
    printf "${bold}${red}Invalid GUID: '%s'. Expected 8-4-4-4-12 hex.${normal}\n" "$_guid" >/dev/tty
  done
}

check_backend_reachable() {
  # Warn (never fail) if this host can't reach the backend base URL "$1". The
  # agent posts to "$1/agents/<account>/collector-client/refresh"; a scheme/port
  # mismatch surfaces here instead of as a silent 100s timeout once it starts.
  # wget exit 8 = the server answered with an HTTP error, which still proves reach.
  verbose "Checking backend connectivity to $1..."
  _rc=0
  wget -q --spider -T 10 -t 1 "$1" 2>/dev/null || _rc=$?
  if [ "$_rc" -eq 0 ] || [ "$_rc" -eq 8 ]; then
    verbose "Backend $1 is reachable."
    return 0
  fi
  info "${bold}${yellow}Warning:${normal} could not reach the backend at $1 (wget exit $_rc)."
  info "Verify the scheme/port and any firewall between here and the backend."
  info "The agent will keep retrying, but can't register or ship data until this connects."
}

opt_hostname='localhost'
opt_account='00000000-0000-0000-0000-000000000000'
opt_registration_token=''
opt_data_root='/logship'
opt_path='/opt/logship'
opt_database_port='5000'
opt_database_password="$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 10)"
opt_frontend_port='8000'
opt_tag="latest"
opt_agent=''
opt_database=''
opt_frontend=''
opt_noinstall=''
opt_verbose=''
opt_help=''
opt_overwrite=''
opt_yes=''

database_config_updated='false'
database_password_updated='false'

# Track which options were passed explicitly so interactive mode doesn't re-prompt
# for them (and never echoes an arg'd secret). Space-delimited option names.
explicit_opts=''

# parse command-line options
set -- "$@" "${EOL:=$(printf '\1\3\3\7')}" # end-of-list marker
while [ "$1" != "$EOL" ]; do
  opt="$1"
  shift
  # shellcheck disable=SC2295,SC2034
  case "$opt" in
  # Services
  -a | --agent) opt_agent=true ;;
  -d | --database) opt_database=true ;;
  -f | --frontend) opt_frontend=true ;;
  -c | --cli) err "CLI installation is not supported by this installer. Install logsh separately." ;;

  # Install options
  -p | --path)
    check "$1" "$opt"
    opt_path="${1%%/}"
    explicit_opts="$explicit_opts path"
    shift
    ;;
  --hostname)
    check "$1" "$opt"
    opt_hostname="${1%%/}"
    explicit_opts="$explicit_opts hostname"
    shift
    ;;
  --account)
    check "$1" "$opt"
    check_guid "$1"
    opt_account="$1"
    explicit_opts="$explicit_opts account"
    shift
    ;;
  --registration-token)
    check "$1" "$opt"
    opt_registration_token="$1"
    explicit_opts="$explicit_opts registration-token"
    shift
    ;;
  --overwrite) opt_overwrite=true ;;
  --data-root)
    check "$1" "$opt"
    opt_data_root="${1%%/}"
    explicit_opts="$explicit_opts data-root"
    shift
    ;;
  --database-port)
    check "$1" "$opt"
    check_port "$1"
    opt_database_port="$1"
    explicit_opts="$explicit_opts database-port"
    shift
    ;;
  --frontend-port)
    check "$1" "$opt"
    check_port "$1"
    opt_frontend_port="$1"
    explicit_opts="$explicit_opts frontend-port"
    shift
    ;;
  --preview)
    opt_tag='latest'
    ;;
  --no-install) opt_noinstall=true ;;

    # Installer Script Options
  --no-color)
    bold=""
    underline=""
    standout=""
    normal=""
    black=""
    red=""
    green=""
    yellow=""
    blue=""
    magenta=""
    cyan=""
    white=""
    ;;
  -y | --yes | --non-interactive) opt_yes=true ;;
  -v | --verbose) opt_verbose=true ;;
  -h | --help) opt_help=true ;;

  # process special cases
  --) while [ "$1" != "$EOL" ]; do
    set -- "$@" "$1"
    shift
  done ;;                                                                # parse remaining as positional
  --[!=]*=*) set -- "${opt%%=*}" "${opt#*=}" "$@" ;;                     # "--opt=arg"  ->  "--opt" "arg"
  -[A-Za-z0-9] | -*[!A-Za-z0-9]*) invalid_arg "invalid option" "$opt" ;; # anything invalid like '-*'
  -?*)
    other="${opt#-?}"
    set -- "${opt%$other}" "-${other}" "$@"
    ;;                     # "-abc"  ->  "-a" "-bc"
  *) set -- "$@" "$opt" ;; # positional, rotate to the end
  esac
done
shift

if [ "$opt_help" = "true" ]; then
  printf "%slogship installer%s\n\n" "$bold" "$normal"
  verbose_ship
  usage
  exit 0
fi

# Remember whether the user explicitly picked components before we prompt/default.
components_explicit=false
if [ -n "$opt_agent" ] || [ -n "$opt_database" ] || [ -n "$opt_frontend" ]; then
  components_explicit=true
fi

interactive_config() {
  info "Interactive setup. Press enter to accept each [default]. Re-run with ${cyan}-y${normal} for an unattended install."

  if [ "$components_explicit" != 'true' ]; then
    if ask_yn 'Install the logship database?' Y; then opt_database=true; fi
    if ask_yn 'Install the logship frontend?' Y; then opt_frontend=true; fi
    if ask_yn 'Install the logship agent?' Y; then opt_agent=true; fi
  fi

  was_set hostname || opt_hostname="$(ask 'Hostname' "$opt_hostname")"
  if ! was_set path; then
    opt_path="$(ask 'Install directory' "$opt_path")"
    opt_path="${opt_path%%/}"
  fi

  if [ "$opt_database" = 'true' ]; then
    was_set database-port || opt_database_port="$(ask_port 'Database listen port' "$opt_database_port")"
    if ! was_set data-root; then
      opt_data_root="$(ask 'Data directory' "$opt_data_root")"
      opt_data_root="${opt_data_root%%/}"
    fi
  fi

  if [ "$opt_frontend" = 'true' ]; then
    was_set frontend-port || opt_frontend_port="$(ask_port 'Frontend listen port' "$opt_frontend_port")"
  fi

  if [ "$opt_agent" = 'true' ]; then
    was_set account || opt_account="$(ask_guid 'Account GUID the agent ships to' "$opt_account")"
    was_set registration-token || opt_registration_token="$(ask_secret 'Agent registration token (blank for none)' "$opt_registration_token")"
  fi
}

was_interactive=false
if is_interactive; then
  was_interactive=true
  interactive_config
fi

# Default install to true if none are specified (unattended run, no components chosen).
if [ "$was_interactive" != 'true' ] && [ -z "$opt_agent" ] && [ -z "$opt_database" ] && [ -z "$opt_frontend" ]; then
  opt_agent=true
  opt_database=true
  opt_frontend=true
fi

if [ "$opt_agent" != 'true' ] && [ "$opt_database" != 'true' ] && [ "$opt_frontend" != 'true' ]; then
  err "No components selected to install. Choose the agent, database, and/or frontend."
fi

# Sanitize the identifier values written into the JSON config. Hostnames, GUIDs,
# and registration tokens (JWTs) never contain whitespace, so strip any that slipped
# in — e.g. a trailing newline from `RTOKEN=$(cat token)` or a wrapped paste — which
# would otherwise land as a raw newline inside a JSON string and break the config.
# (Paths are left alone: they may legitimately contain spaces.)
opt_hostname=$(printf '%s' "$opt_hostname" | tr -d '[:space:]')
opt_account=$(printf '%s' "$opt_account" | tr -d '[:space:]')
opt_registration_token=$(printf '%s' "$opt_registration_token" | tr -d '[:space:]')

# Derive the backend URL (scheme-aware) and a bare host for display messages.
# Accepts a pasted URL from both interactive and --hostname input.
opt_backend_url="$(backend_url "$opt_hostname" "$opt_database_port")"
display_host="$(clean_hostname "$opt_hostname")"

ensure() {
  if ! "$@"; then err "command failed: $*"; fi
}

need_cmd() {
  if ! check_cmd "$1"; then
    err "need '$1' (command not found)"
  fi
}

need_cmds() {
  missing_cmds=""
  for cmd in "$@"; do
    if ! check_cmd "$cmd"; then
      if [ -z "$missing_cmds" ]; then
        missing_cmds="$cmd"
      else
        missing_cmds="$missing_cmds $cmd"
      fi
    fi
  done

  if [ -n "$missing_cmds" ]; then
    err "Install required command(s) to continue. $bold$missing_cmds$normal"
  fi
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_or_sudo() {
  # Root: run directly. Non-root: go straight to sudo — trying the command bare
  # first makes tools like systemctl spawn an interactive polkit password agent,
  # which blocks or fails on passwordless-sudo hosts. No sudo: try directly and
  # hope the target is user-writable.
  # ponytail: sudo is used for every privileged op when non-root, even a
  # user-writable target; fine for a system installer.
  if [ "$(id -u)" -eq 0 ]; then
    ensure "$@"
    verbose "Executed \"$*\"."
  elif check_cmd sudo; then
    info "Elevated permission required to execute \"$*\"."
    ensure sudo "$@"
    info "${cyan}[sudo]${normal} Executed \"$*\"."
  elif "$@" 2>/dev/null; then
    verbose "Executed \"$*\"."
  else
    err "Command failed and sudo is unavailable: $*"
  fi
}

systemd_install() {
  verbose "Creating unit file for $1"
  tempfile="$(mktemp -t "$1-XXXXXXXXXXXXXXXX")"
  cat <<EOF >"$tempfile"
[Unit]
Description=$1
Documentation=https://logship.io/

[Service]
ExecStart=$2/$3
WorkingDirectory=$2
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  run_or_sudo mv -f "$tempfile" "/lib/systemd/system/$1.service"
}

write_agent_config() {
  verbose "Writing agent configuration to $1"
  tempfile="$(mktemp -t "agent-config-XXXXXXXXXXXXXXXX")"
  cat <<EOF >"$tempfile"
{
  "Kestrel": {
    "Endpoints": {
      "Default": {
        "Url": "http://*:57421"
      }
    }
  },
  "Output": {
    "endpoint": "$opt_backend_url",
    "account": "$opt_account",
    "interval": "00:00:01",
    "maximumBufferSize": 40000,
    "maximumFlushSize": 5000,
    "health": {
      "interval": "00:00:05"
    },
    "registration": {
      "registrationToken": "$opt_registration_token"
    }
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "System.Net.Http.HttpClient.Default": "Warning"
    }
  },
  "Sources": {
    "DiskInformation": {
      "enabled": true,
      "interval": "00:00:05"
    },
    "HealthChecks": {
      "enabled": true,
      "targets": [
        {
          "endpoint": "$opt_backend_url",
          "interval": "00:01:00",
          "includeResponseHeaders": true,
          "includeResponseBody": true
        }
      ]
    },
    "JournalCtl": {
      "enabled": true,
      "flags": 0,
      "includeFields": ["USERID"],
      "filters": [
        {
          "matchAny": [
            {
              "hasField": "CONTAINER_NAME"
            },
            {
              "fieldEquals": {
                "field": "SYSLOG_IDENTIFIER",
                "value": "Logship.Agent.ConsoleHost"
              }
            },
            {
              "fieldEquals": {
                "field": "SYSLOG_IDENTIFIER",
                "value": "sshd"
              }
            }
          ]
        }
      ]
    },
    "NetworkInformation": {
      "enabled": true,
      "interval": "00:00:15"
    },
    "Proc": {
      "enabled": true,
      "interval": "00:00:05"
    },
    "Proc.OpenFiles": {
      "enabled": true,
      "interval": "00:05:00"
    },
    "Proc.Modules": {
      "enabled": true,
      "interval": "00:00:10"
    },
    "ProcessInformation": {
      "enabled": true,
      "interval": "00:00:30"
    },
    "SystemInformation": {
      "enabled": true,
      "interval": "01:00:00"
    },
    "UDPListener": {
      "enabled": true,
      "port": 49999
    },
    "Internals": {
      "enabled": true,
      "interval": "00:00:15",
      "enableMetrics": true,
      "enableTracing": true
    }
  }
}
EOF
  run_or_sudo mv -f "$tempfile" "$1"
}

install_agent() {
  agent_path="$opt_path/agent"
  service_name="logship-agent"
  config="appsettings.json"
  exe="Logship.Agent.ConsoleHost"
  file="LogshipAgent-$operating_system-$architecture.zip"
  tempdir="$(mktemp -d -t "installer-$service_name-XXXXXXXXXXXXXXXX")"

  verbose "Using temporary directory $tempdir"
  info "Downloading $service_name..."
  ensure wget "https://github.com/logship-io/logship-agent/releases/latest/download/$file" -P "$tempdir" -q --show-progress
  verbose "Downloaded $service_name."
  run_or_sudo mkdir -p "$agent_path"

  verbose "Extracting files..."
  ensure unzip -qq "$tempdir/$file" -d "$tempdir/extract"
  run_or_sudo cp -f "$tempdir/extract/$exe" "$agent_path/$exe"
  run_or_sudo chmod +x "$agent_path/$exe"

  verbose "Cleaning up $tempdir"
  rm -rf "$tempdir"

  if [ ! -e "$agent_path/$config" ] && [ -z "$opt_overwrite" ]; then
    write_agent_config "$agent_path/$config"
  else
    if [ "$opt_overwrite" = 'true' ]; then
      info "--overwrite: Overwriting existing agent configuration."
      write_agent_config "$agent_path/$config"
    else
      verbose "Agent configuration \"$agent_path/$config\" already exists. Use --overwrite to overwrite existing configuration."
    fi
  fi

  if [ -z "$opt_noinstall" ]; then
    if systemctl list-unit-files | grep -q "^$service_name.service"; then
      verbose "The $service_name service already exists"
      # Check if the service is running
      if systemctl is-active --quiet "$service_name"; then
        # Stop the service
        sudo systemctl stop "$service_name"
        verbose "Stopped the $service_name service."
      else
        verbose "The $service_name service is not running."
      fi
    else
      verbose "The $service_name service does not exist."
      systemd_install "$service_name" "$opt_path/agent" "$exe"
    fi

    run_or_sudo systemctl enable "$service_name.service"
    # Don't auto-start the agent: let the user review/edit the config first.
    # The final install message tells them how to start it.
  else
    verbose "Skipping installation of $service_name"
  fi

  info "Configuration of $service_name complete."
}

write_database_config() {
  verbose "Writing database configuration to $1"
  tempfile="$(mktemp -t "database-XXXXXXXXXXXXXXXX")"
  cat <<EOF >"$tempfile"
{
  "DataRoot": "$opt_data_root",
  "ListenPort": $opt_database_port,
  "agent": {
    "udpMetricsEndpoint": "127.0.0.1:49999"
  },
  "database": {
    "enable": true,
    "master": {
      "enable": true
    },
    "endpoints": {
      "worker": [
        "net.tcp://0.0.0.0:6000"
      ],
      "master": [
        "net.tcp://127.0.0.1:6000"
      ]
    },
    "services": {
      "keyvalue": {
        "enable": true,
        "dataPath": "$opt_data_root/kvs"
      },
      "transactionManager": {
        "enable": true
      },
      "transactionLog": {
        "enable": true,
        "disk": {
          "enable": true,
          "path": "$opt_data_root/tlog"
        },
        "memory": {
          "enable": false
        }
      },
      "gateway": {
        "enable": true
      },
      "partitionManager": {
        "enable": true
      }
    }
  },
  "backend": {
    "enable": true,
    "endpoints": {
      "worker": [
        "net.tcp://0.0.0.0:6002"
      ],
      "master": [
        "net.tcp://127.0.0.1:6002"
      ]
    },
    "database": {
      "worker": [
        "net.tcp://127.0.0.1:6000"
      ],
      "master": [
        "net.tcp://127.0.0.1:6000"
      ]
    },
    "services": {
      "configService": {
        "enable": true
      },
      "inflowService": {
        "enable": true
      },
      "collectorService": {
        "enable": true,
        "tempPath": "$opt_data_root/tmp/"
      },
      "searchExecutorService": {
        "enable": true,
        "dataPath": "$opt_data_root/searchdata/",
        "minimumFreeSpaceBytes": 5368709120,
        "minimumFreeSpacePercentage": 15.0
      },
      "searchQueryService": {
        "enable": true
      },
      "accountsService": {
        "enable": true,
        "jwt": {
          "enable": true,
          "issuer": "logship",
          "audience": "logship",
          "signingKey": "Default signing key for your application. You should change this in a production environment."
        }
      },
      "messengerService": {
        "enable": true
      },
      "dashboardService": {
        "enable": true
      },
      "evaluatorManagerService": {
        "enable": true
      },
      "evaluatorRunnerService": {
        "enable": true
      },
      "setupService": {
        "enable": true,
        "provision": true,
        "accounts": [
          {
            "accountId": "$opt_account",
            "accountName": "Default Account"
          }
        ],
        "users": [
          {
            "userId": "00000000-0000-0000-0000-00000000cafe",
            "username": "admin",
            "password": "$opt_database_password",
            "firstname": "Logship",
            "lastname": "Admin",
            "email": "admin@example.com",
            "defaultGlobalPermissions": [
              "Logship.Global.Admin"
            ],
            "defaultAccounts": [
              {
                "accountName": "Default Account",
                "userPermissions": [
                  "Logship.Account.Admin"
                ]
              }
            ]
          }
        ]
      }
    },
    "master": {
      "enable": true
    }
  }
}
EOF
  run_or_sudo mv -f "$tempfile" "$1"
}

install_database() {
  database_path="$opt_path/database"
  service_name="logship-database"
  config="appsettings.json"
  exe="Logship.Host.ConsoleHost"
  file="${service_name}_${operating_system}-${architecture}.zip"
  tempdir="$(mktemp -d -t "installer-$service_name-XXXXXXXXXXXXXXXX")"

  verbose "Using temporary directory $tempdir"
  info "Downloading $service_name..."
  verbose "Download URL: https://ar.logship.io/release/${service_name}/${operating_system}-${architecture}/${opt_tag}"
  ensure wget "https://ar.logship.io/release/${service_name}/${operating_system}-${architecture}/${opt_tag}" -P "$tempdir" -q --show-progress
  verbose "Downloaded $service_name."
  run_or_sudo mkdir -p "$opt_data_root"
  run_or_sudo mkdir -p "$database_path"

  verbose "Extracting files..."
  ensure unzip -qq "$tempdir/$opt_tag" -d "$tempdir/extract"
  rm "$tempdir/extract/appsettings.json" 2>/dev/null
  rm "$tempdir/extract/appsettings.Development.json" 2>/dev/null

  run_or_sudo cp -rf "$tempdir/extract/." "$database_path"
  run_or_sudo chmod +x "$database_path/$exe"

  verbose "Cleaning up $tempdir"
  rm -rf "$tempdir"

  if [ ! -e "$database_path/$config" ] && [ -z "$opt_overwrite" ]; then
    write_database_config "$database_path/$config"
    database_config_updated='true'
    database_password_updated='true'
  else
    if [ "$opt_overwrite" = 'true' ]; then
      if [ -z "$(find "$opt_data_root" -mindepth 1 -maxdepth 1 -type f -o -type d)" ]; then
        database_password_updated='true'
      else
        info "The data directory is not empty. Admin password won't be updated. Delete datafiles files in \"$opt_data_root\" to reset to the password in configuration."
      fi

      info "--overwrite: Overwriting existing database configuration."
      write_database_config "$database_path/$config"
      database_config_updated='true'
    else
      verbose "Database configuration \"$database_path/$config\" already exists. Use --overwrite to overwrite existing configuration."
    fi
  fi

  if [ -z "$opt_noinstall" ]; then
    if systemctl list-unit-files | grep -q "^$service_name.service"; then
      verbose "The $service_name service already exists"
      # Check if the service is running
      if systemctl is-active --quiet "$service_name"; then
        # Stop the service
        sudo systemctl stop "$service_name"
        verbose "Stopped the $service_name service."
      else
        verbose "The $service_name service is not running."
      fi
    else
      verbose "The $service_name service does not exist."
      systemd_install "$service_name" "$opt_path/database" "$exe"
    fi

    run_or_sudo systemctl enable "$service_name.service"
    run_or_sudo systemctl restart "$service_name.service"
  else
    verbose "Skipping installation of $service_name"
  fi

  info "Configuration of $service_name complete."
}

write_frontend_config() {
  verbose "Writing frontend configuration to $1"
  tempfile="$(mktemp -t "frontend-XXXXXXXXXXXXXXXX")"
  cat <<EOF >"$tempfile"
{
  "AllowedHosts": "*",
  "Kestrel": {
    "Endpoints": {
      "Http": {
        "Url": "http://+:$opt_frontend_port"
      }
    }
  },
  "ClientSettings": {
    "BackendUrl": "$opt_backend_url",
    "MetricsInflowRootSchema": "logship.frontend.ui.",
    "MetricsInflowAccount": "$opt_account"
  }
}
EOF
  run_or_sudo mv -f "$tempfile" "$1"
}

install_frontend() {
  frontend_path="$opt_path/frontend"
  service_name="logship-frontend"
  config="appsettings.json"
  exe="fe-react"
  file="${service_name}_${operating_system}-${architecture}.zip"
  tempdir="$(mktemp -d -t "installer-$service_name-XXXXXXXXXXXXXXXX")"

  run_or_sudo mkdir -p "$frontend_path"
  verbose "Using temporary directory $tempdir"
  info "Downloading $service_name..."
  verbose "Download URL: https://ar.logship.io/release/${service_name}/${operating_system}-${architecture}/${opt_tag}"
  ensure wget "https://ar.logship.io/release/${service_name}/${operating_system}-${architecture}/${opt_tag}" -P "$tempdir" -q --show-progress
  verbose "Downloaded $service_name."

  verbose "Extracting files..."
  ensure unzip -qq "$tempdir/$opt_tag" -d "$tempdir/extract"
  rm "$tempdir/extract/appsettings.json" 2>/dev/null
  rm "$tempdir/extract/appsettings.Development.json" 2>/dev/null

  run_or_sudo cp -rf "$tempdir/extract/." "$frontend_path"
  run_or_sudo chmod +x "$frontend_path/$exe"

  verbose "Cleaning up $tempdir"
  rm -rf "$tempdir"

  if [ ! -e "$frontend_path/$config" ] && [ -z "$opt_overwrite" ]; then
    write_frontend_config "$frontend_path/$config"
  else
    if [ "$opt_overwrite" = 'true' ]; then
      info "--overwrite: Overwriting existing frontend configuration."
      write_frontend_config "$frontend_path/$config"
    else
      verbose "Frontend configuration \"$frontend_path/$config\" already exists. Use --overwrite to overwrite existing configuration."
    fi
  fi

  if [ -z "$opt_noinstall" ]; then
    if systemctl list-unit-files | grep -q "^$service_name.service"; then
      verbose "The $service_name service already exists"
      # Check if the service is running
      if systemctl is-active --quiet "$service_name"; then
        # Stop the service
        sudo systemctl stop "$service_name"
        verbose "Stopped the $service_name service."
      else
        verbose "The $service_name service is not running."
      fi
    else
      verbose "The $service_name service does not exist."
      systemd_install "$service_name" "$opt_path/frontend" "$exe"
    fi

    run_or_sudo systemctl enable "$service_name.service"
    run_or_sudo systemctl restart "$service_name.service"
  else
    verbose "Skipping installation of $service_name"
  fi

  info "Configuration of $service_name complete."
}

write_uninstall() {
  verbose "Writing uninstall script to $opt_path/uninstall.sh"
  tempfile="$(mktemp -t "uninstall-XXXXXXXXXXXXXXXX")"
  cat <<EOF >"$tempfile"
#!/bin/sh
if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$0" "\$@"
fi
printf '%s' "Uninstall logship? (y/n): This will delete everything under \"$opt_path\". "
read -r choice
case "\$choice" in
[Yy]|[Yy][Ee][Ss])
  systemctl disable logship-agent.service
  systemctl disable logship-database.service
  systemctl disable logship-frontend.service
  systemctl stop logship-agent.service
  systemctl stop logship-database.service
  systemctl stop logship-frontend.service
  rm -f /lib/systemd/system/logship-agent.service
  rm -f /lib/systemd/system/logship-database.service
  rm -f /lib/systemd/system/logship-frontend.service
  systemctl daemon-reload
  rm -rf "$opt_path"
  echo "Done"
  exit 0
  ;;
[Nn]|[Nn][Oo])
  echo "Exiting"
  exit 0
  ;;
*)
  echo "Invalid choice, please enter 'y' or 'n'."
  exit 1
  ;;
esac
EOF
  run_or_sudo mv -f "$tempfile" "$opt_path/uninstall.sh"
  run_or_sudo chmod +x "$opt_path/uninstall.sh"
}

main() {
  need_cmds chmod cp echo find grep head id mkdir mktemp mv rm rmdir sudo tee tr uname unzip wget
  if [ -z "$opt_noinstall" ]; then
    if [ "$operating_system" != "linux" ]; then
      err "Service installation requires Linux with systemd. Re-run with --no-install on $operating_system."
    fi

    need_cmd systemctl
  fi

  verbose_ship
  verbose "Root installation path: $opt_path"

  if [ "$opt_agent" = 'true' ]; then
    install_agent
  fi

  if [ "$opt_database" = 'true' ]; then
    install_database
  fi

  if [ "$opt_frontend" = 'true' ]; then
    install_frontend
  fi

  write_uninstall

  info "Installation complete."
  info "Uninstall by running \"${cyan}$opt_path/uninstall.sh${normal}\"."
  if [ "$opt_database" = 'true' ] && [ "$database_config_updated" = 'true' ]; then
    info "Your database is accessible at http://$display_host:$opt_database_port."
    if [ "$database_password_updated" = 'true' ]; then
      info "    Username: admin"
      info "    Password: $opt_database_password"
      info "You should probably change this password. You can also find it in \"$opt_path/database/appsettings.json\"."
    fi
  fi
  if [ "$opt_frontend" = 'true' ]; then
    if systemctl is-active --quiet "logship-frontend"; then
      info "Your frontend is accessible at http://$display_host:$opt_frontend_port"
    fi
  fi
  if [ "$opt_agent" = 'true' ]; then
    info "Agent shipping to $opt_backend_url (account $opt_account)."
    info "Review/edit the agent config at \"${cyan}$opt_path/agent/appsettings.json${normal}\"."
    if [ -z "$opt_noinstall" ]; then
      info "Then start the agent with \"${cyan}sudo systemctl start logship-agent${normal}\"."
    fi
  fi
  if [ "$display_host" != 'localhost' ]; then
    info "If you'd like to make your instance externally accessible, see https://docs.logship.io/database/v0.0.1/config/#backend for security guidance"
  fi
}

main "$@" || exit 1
