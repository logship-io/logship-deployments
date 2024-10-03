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
  e.g. ${CMD:=${0##*/}} -acdf ${green}# install all logship services & tools.${normal}

  Providing no download/install arguments will install all available services & tools.

${bold}Options:${normal}
  ${cyan}-a${normal}, ${cyan}--agent${normal}
          Download and configure the logship agent
  ${cyan}-c${normal}, ${cyan}--cli${normal}
          Download and configure the logship CLI (logsh)
  ${cyan}-d${normal}, ${cyan}--database${normal}
          Download and configure the logship database
  ${cyan}-f${normal}, ${cyan}--frontend${normal}
          Download and configure the logship frontend

      ${cyan}--hostname${normal}
          [default: localhost] Set the hostname
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

check_port() {
  # shellcheck disable=SC2046,SC2143
  if [ $(echo "$1" | grep -q "^[0-9]+$") ] && [ "$1" -ge 0 ] && [ "$1" -le 65535 ]; then
    return 0
  else
    err "Argument value \"$1\" is not a valid port."
  fi
}

opt_hostname='localhost'
opt_data_root='/logship'
opt_path='/opt/logship'
opt_database_port='5000'
opt_database_password="$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 10)"
opt_frontend_port='8000'
opt_tag="latest-pre"
opt_agent=''
opt_cli=''
opt_database=''
opt_frontend=''
opt_noinstall=''
opt_verbose=''
opt_help=''
opt_overwrite=''

database_config_updated='false'
database_password_updated='false'

# parse command-line options
set -- "$@" "${EOL:=$(printf '\1\3\3\7')}" # end-of-list marker
while [ "$1" != "$EOL" ]; do
  opt="$1"
  shift
  # shellcheck disable=SC2295,SC2034
  case "$opt" in
  # Services
  -a | --agent) opt_agent=true ;;
  -c | --cli) opt_cli=true ;;
  -d | --database) opt_database=true ;;
  -f | --frontend) opt_frontend=true ;;

  # Install options
  -p | --path)
    check "$1" "$opt"
    opt_path="${1%%/}"
    shift
    ;;
  --hostname)
    check "$1" "$opt"
    opt_hostname="${1%%/}"
    shift
    ;;
  --overwrite) opt_overwrite=true ;;
  --data-root)
    check "$1" "$opt"
    opt_data_root="${1%%/}"
    shift
    ;;
  --database-port)
    check "$1" "$opt"
    check_port "$1"
    opt_database_port="$1"
    shift
    ;;
  --frontend-port)
    check "$1" "$opt"
    check_port "$1"
    opt_frontend_port="$1"
    shift
    ;;
  --preview)
    opt_tag='latest-pre'
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

# Default install to true if none are specified.
if [ -z "$opt_agent" ] && [ -z "$opt_database" ] && [ -z "$opt_frontend" ] && [ -z "$opt_cli" ]; then
  opt_agent=true
  opt_database=true
  opt_frontend=true
  opt_cli=true
fi

service_exists() {
  # shellcheck disable=SC2046,SC2143
  if [ $(systemctl status "$1" 2>/dev/null | grep -Fq "Active:") ]; then
    return 1
  else
    return 0
  fi
}

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
  if "$@" 2>/dev/null; then
    verbose "Executed \"$*\"."
    return 0
  else
    if [ "$(sudo -n true 2>/dev/null)" = "0" ]; then
      err "Command failed: $*"
    else
      info "Elevated permission required to execute \"$*\"."
      ensure sudo "$@"
      info "${cyan}[sudo]${normal} Executed \"$*\"."
    fi
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
  sudo mv -f "$tempfile" "/lib/systemd/system/$1.service"
}

write_agent_config() {
  verbose "Writing agent configuration to $1"
  tempfile="$(mktemp -t "agent-config-XXXXXXXXXXXXXXXX")"
  cat <<EOF >"$tempfile"
{
  // Agent output configuration.
  "Output": {
    // Update your output endpoint here.
    // This should match the host/port of your logship database.
    "endpoint": "http://$opt_hostname:$opt_database_port",

    // The account to upload to
    "account": "00000000-0000-0000-0000-000000000000",

    // Upload interval
    "interval": "00:00:02",
  },

  // Agent source configuration
  "Sources": {
    "DiskInformation": {
      "enabled": true,
      "interval": "00:00:05"
    },
    "JournalCtl": {
      "enabled": true,
      "flags": 0,
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
    run_or_sudo systemctl start "$service_name.service"
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
  "ListenPort": "$opt_database_port",
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
        },
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
            "accountId": "00000000-0000-0000-0000-000000000000",
            "accountName": "Default Account"
          },
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
          },
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
    "BackendUrl": "http://$opt_hostname:$opt_database_port",
    "MetricsInflowRootSchema": "logship.frontend.ui.",
    "MetricsInflowAccount": "00000000-0000-0000-0000-000000000000",
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
read -p "Uninstall logship? (y/n): This will delete everything under \"$opt_path\"." choice
case "\$choice" in
[Yy]|[Yy][Ee][Ss])
  systemctl disable logship-agent.service
  systemctl disable logship-database.service
  systemctl disable logship-frontend.service
  systemctl stop logship-agent.service
  systemctl stop logship-database.service
  systemctl stop logship-frontend.service
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
  need_cmds chmod echo find head mkdir mktemp rm rmdir sudo tee tr unzip wget
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

  # if [ "$opt_cli" = 'true' ]; then
  #     install_logsh
  # fi

  write_uninstall

  info "Installation complete."
  info "Uninstall with \"${cyan}sudo $opt_path/uninstall.sh${normal}\"."
  if [ "$opt_database" = 'true' ] && [ "$database_config_updated" = 'true' ]; then
    info "Your database is accessible at http://$opt_hostname:$opt_database_port."
    if [ "$database_password_updated" = 'true' ]; then
      info "    Username: admin"
      info "    Password: $opt_database_password"
      info "You should probably change this password. You can also find it in \"$opt_path/database/appsettings.json\"."
    fi
  fi
  if [ "$opt_frontend" = 'true' ]; then
    if systemctl is-active --quiet "logship-frontend"; then
      info "Your frontend is accessible at http://$opt_hostname:$opt_frontend_port"
    fi
  fi
  if [ "$opt_hostname" != 'localhost' ]; then
    info "If you'd like to make your instance externally accessible, don't forget to update firewall rules!"
  fi
}

main "$@" || exit 1
