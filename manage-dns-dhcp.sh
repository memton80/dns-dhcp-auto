#!/bin/bash
#==============================================================================
#  DNS-DHCP AUTO - Installation et gestion de BIND9 et de Kea DHCP4
#
#  Interface console maison (aucune dependance a whiptail / dialog) :
#    - panneau "Machine et services" en haut a droite
#    - grand panneau de configuration avec menus depliants
#    - barre de boutons en bas : APPLIQUER / ACTIONS / DIAGNOSTIC / QUITTER
#    - ecrans de traitement avec Tux anime et barre de progression reelle
#
#  Ce script n'est pas seulement un installateur : il conserve sa
#  configuration dans /etc/dns-dhcp-auto/config.conf et sert ensuite de
#  console de gestion (services, zones, enregistrements, baux, reservations,
#  pare-feu, sauvegardes, journaux, desinstallation).
#
#  Auteur : memton80
#==============================================================================

set -o pipefail

#------------------------------------------------------------------ constantes
SCRIPT_VERSION="1.0"

LOGFILE="/var/log/dns-dhcp-auto.log"
STEP_LOG="/tmp/ddauto-step.log"
APT_STATUS="/tmp/ddauto-apt-status.log"

CONF_DIR="/etc/dns-dhcp-auto"
CONF_FILE="$CONF_DIR/config.conf"
BACKUP_DIR="/var/backups/dns-dhcp-auto"

BIND_DIR="/etc/bind"
BIND_ZONE_DIR="/etc/bind/zones"
BIND_OPTIONS="/etc/bind/named.conf.options"
BIND_LOCAL="/etc/bind/named.conf.local"
BIND_LOGDIR="/var/log/named"
DDNS_KEY_FILE="/etc/bind/ddns.key"

KEA_DIR="/etc/kea"
KEA_CONF="/etc/kea/kea-dhcp4.conf"
KEA_D2_CONF="/etc/kea/kea-dhcp-ddns.conf"
KEA_LEASES="/var/lib/kea/kea-leases4.csv"
KEA_LOGDIR="/var/log/kea"
KEA_SOCKET="/run/kea/kea4-ctrl-socket"
KEA_D2_PORT=53001

UNINSTALL_PATH="./uninstall-dns-dhcp.sh"

# Unites systemd, resolues au demarrage (Debian 12 expose "named" et son alias
# "bind9", certaines images n'ont que l'un des deux).
BIND_UNIT="named"
DHCP_UNIT="kea-dhcp4-server"
D2_UNIT="kea-dhcp-ddns-server"

# Version de Kea, lue au premier besoin. Elle decide de quelques noms de
# parametres qui ont change entre Kea 2.2 (Debian 12) et Kea 2.6 (Debian 13).
KEA_VER=""

# Marqueurs poses dans les fichiers generes : ils permettent de reconnaitre un
# fichier ecrit par ce script et de ne jamais ecraser silencieusement celui
# d'un administrateur.
GEN_MARK="# --- genere par dns-dhcp-auto ---"

# Derniere ligne de tout fichier genere. Sa presence prouve que l'ecriture est
# allee jusqu'au bout : sans elle, on saurait qu'un fichier existe, jamais
# qu'il est complet.
GEN_END="dns-dhcp-auto:eof"

export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"
export DEBIAN_FRONTEND=noninteractive

RESIZED=0
DIRTY=0                 # 1 = la configuration a change depuis le dernier apply

#------------------------------------------------------- distribution detectee
# OS_ID       : "debian", "ubuntu"...
# OS_VER      : numero de version majeur (12, 13...), 0 si illisible
# OS_CODENAME : "bookworm", "trixie"...
# OS_LABEL    : libelle court affiche dans l'interface ("DEBIAN 12")
#
# La version compte : Debian 12 livre Kea 2.2 et Debian 13 livre Kea 2.6, qui
# n'acceptent pas exactement les memes noms de parametres. Le script s'adapte
# a la version reellement installee plutot que de figer un seul format.
OS_ID="debian"
OS_VER=0
OS_CODENAME=""
OS_LABEL="DEBIAN"

detect_os_release() {
    local id="" ver="" code=""
    if [[ -r /etc/os-release ]]; then
        id=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
        ver=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}")
        code=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")
    fi
    [[ -n $id ]] && OS_ID=$id
    OS_CODENAME=$code
    ver=${ver%%.*}
    if [[ $ver =~ ^[0-9]+$ ]]; then OS_VER=$ver; else OS_VER=0; fi

    OS_LABEL=${OS_ID^^}
    (( OS_VER > 0 )) && OS_LABEL="$OS_LABEL $OS_VER"
}

# Resout le nom reel des unites systemd une fois les paquets installes.
detect_units() {
    local list
    list=$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null | awk '{print $1}')
    if printf '%s\n' "$list" | grep -qx 'named.service'; then
        BIND_UNIT="named"
    elif printf '%s\n' "$list" | grep -qx 'bind9.service'; then
        BIND_UNIT="bind9"
    fi
    if printf '%s\n' "$list" | grep -qx 'kea-dhcp4-server.service'; then
        DHCP_UNIT="kea-dhcp4-server"
    fi
    if printf '%s\n' "$list" | grep -qx 'kea-dhcp-ddns-server.service'; then
        D2_UNIT="kea-dhcp-ddns-server"
    fi
}

# Version de Kea sous la forme "majeur.mineur", vide si Kea est absent.
detect_kea_version() {
    [[ -n $KEA_VER ]] && return 0
    command -v kea-dhcp4 >/dev/null 2>&1 || return 1
    local v
    v=$(kea-dhcp4 -V 2>/dev/null | head -n1)
    if [[ $v =~ ([0-9]+)\.([0-9]+) ]]; then
        KEA_VER="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

# Kea a renomme "output_options" en "output-options" dans la serie 2.6 : la
# serie 2.4 refuse encore le nouveau nom, la 2.6 accepte les deux. On ecrit
# celui que la version installee connait a coup sur ; si la detection se
# trompe malgre tout, do_check_dhcp echange les deux et recommence.
KEA_OUTKEY_FORCE=""

kea_output_key() {
    local maj=0 min=0
    if [[ -n $KEA_OUTKEY_FORCE ]]; then
        printf '%s' "$KEA_OUTKEY_FORCE"
        return 0
    fi
    if detect_kea_version; then
        maj=${KEA_VER%%.*}
        min=${KEA_VER##*.}
    fi
    if (( maj > 2 || (maj == 2 && min >= 6) )); then
        printf 'output-options'
    else
        printf 'output_options'
    fi
}

#==============================================================================
#  1. TERMINAL : locale, couleurs, caracteres de cadre
#==============================================================================

setup_locale() {
    if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
        if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then
            export LC_ALL="C.UTF-8" LANG="C.UTF-8"
        elif locale -a 2>/dev/null | grep -qiE '^fr_FR\.utf-?8$'; then
            export LC_ALL="fr_FR.UTF-8" LANG="fr_FR.UTF-8"
        fi
    fi
    if [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]]; then
        UTF8=1
    else
        UTF8=0
    fi
}

setup_charset() {
    if (( UTF8 )); then
        BX_TL='┌'; BX_TR='┐'; BX_BL='└'; BX_BR='┘'; BX_H='─'; BX_V='│'
        BAR_FULL='█'; BAR_EMPTY='░'; GROUND='─'
    else
        BX_TL='+'; BX_TR='+'; BX_BL='+'; BX_BR='+'; BX_H='-'; BX_V='|'
        BAR_FULL='#'; BAR_EMPTY='.'; GROUND='-'
    fi
}

# THEME vaut "dark" (fond sombre) ou "light" (fond clair).
THEME="dark"

# Demande au terminal la couleur de son fond (OSC 11) pour choisir la palette.
# En cas de non-reponse on retombe sur le theme sombre.
detect_theme() {
    case "${DDAUTO_THEME:-}" in
        light|clair)  THEME="light"; return ;;
        dark|sombre)  THEME="dark";  return ;;
    esac

    THEME="dark"
    local resp="" r g b lum saved=""
    if [[ -t 0 && -t 1 ]]; then
        saved=$(stty -g 2>/dev/null)
        stty -echo 2>/dev/null
        printf '\e]11;?\e\\'
        IFS= read -rs -d '\' -t 0.3 resp 2>/dev/null
        [[ -n $saved ]] && stty "$saved" 2>/dev/null
    fi
    if [[ $resp =~ rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4}) ]]; then
        # les composantes font 1 a 4 chiffres hexa : on ne garde que le poids fort
        r=$(( 16#${BASH_REMATCH[1]:0:2} ))
        g=$(( 16#${BASH_REMATCH[2]:0:2} ))
        b=$(( 16#${BASH_REMATCH[3]:0:2} ))
        lum=$(( (r * 299 + g * 587 + b * 114) / 1000 ))
        (( lum > 127 )) && THEME="light"
        return
    fi
    if [[ -n ${COLORFGBG:-} ]]; then
        local bg=${COLORFGBG##*;}
        [[ $bg =~ ^[0-9]+$ ]] && (( bg >= 7 )) && THEME="light"
    fi
}

toggle_theme() {
    if [[ $THEME == dark ]]; then THEME="light"; else THEME="dark"; fi
    setup_colors
}

setup_colors() {
    local ncol=8
    command -v tput >/dev/null 2>&1 && ncol=$(tput colors 2>/dev/null || echo 8)
    [[ "$ncol" =~ ^[0-9]+$ ]] || ncol=8

    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_REV=$'\e[7m'

    if (( ncol >= 256 )); then
        if [[ $THEME == light ]]; then
            C_FRAME=$'\e[38;5;245m'      # cadre inactif
            C_FRAME_ON=$'\e[38;5;25m'    # cadre du panneau actif
            C_TITLE=$'\e[38;5;25m'       # titres de panneaux
            C_LABEL=$'\e[38;5;238m'
            C_VALUE=$'\e[38;5;16m'
            C_OK=$'\e[38;5;28m'
            C_WARN=$'\e[38;5;130m'
            C_ERR=$'\e[38;5;124m'
            C_MUTED=$'\e[38;5;242m'
            C_SEC=$'\e[38;5;54m'
            C_SEL=$'\e[48;5;253m'
            C_BTN=$'\e[38;5;25m'
            C_BTN_ON=$'\e[48;5;25m\e[38;5;231m'
            C_TUX=$'\e[38;5;16m'
            C_TUX_FEET=$'\e[38;5;130m'
            C_BAR=$'\e[38;5;25m'
            C_BAR_BG=$'\e[38;5;252m'
        else
            C_FRAME=$'\e[38;5;240m'
            C_FRAME_ON=$'\e[38;5;75m'
            C_TITLE=$'\e[38;5;81m'
            C_LABEL=$'\e[38;5;250m'
            C_VALUE=$'\e[38;5;231m'
            C_OK=$'\e[38;5;114m'
            C_WARN=$'\e[38;5;214m'
            C_ERR=$'\e[38;5;203m'
            C_MUTED=$'\e[38;5;244m'
            C_SEC=$'\e[38;5;147m'
            C_SEL=$'\e[48;5;238m'
            C_BTN=$'\e[38;5;75m'
            C_BTN_ON=$'\e[48;5;75m\e[38;5;16m'
            C_TUX=$'\e[38;5;255m'
            C_TUX_FEET=$'\e[38;5;214m'
            C_BAR=$'\e[38;5;75m'
            C_BAR_BG=$'\e[38;5;238m'
        fi
    else
        if [[ $THEME == light ]]; then
            C_FRAME=$'\e[90m'; C_FRAME_ON=$'\e[34m'; C_TITLE=$'\e[34m'
            C_LABEL=$'\e[30m'; C_VALUE=$'\e[30m'; C_OK=$'\e[32m'
            C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_MUTED=$'\e[90m'
            C_SEC=$'\e[35m'; C_SEL=$'\e[7m'; C_BTN=$'\e[34m'
            C_BTN_ON=$'\e[44m\e[97m'; C_TUX=$'\e[30m'; C_TUX_FEET=$'\e[33m'
            C_BAR=$'\e[34m'; C_BAR_BG=$'\e[37m'
        else
            C_FRAME=$'\e[90m'; C_FRAME_ON=$'\e[36m'; C_TITLE=$'\e[36m'
            C_LABEL=$'\e[37m'; C_VALUE=$'\e[97m'; C_OK=$'\e[32m'
            C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_MUTED=$'\e[90m'
            C_SEC=$'\e[36m'; C_SEL=$'\e[100m'; C_BTN=$'\e[36m'
            C_BTN_ON=$'\e[46m\e[30m'; C_TUX=$'\e[97m'; C_TUX_FEET=$'\e[33m'
            C_BAR=$'\e[36m'; C_BAR_BG=$'\e[90m'
        fi
    fi
}

tui_start() {
    printf '\e[?1049h'   # ecran alternatif
    printf '\e[?25l'     # curseur cache
    stty -echo 2>/dev/null
}

tui_stop() {
    stty echo 2>/dev/null
    printf '\e[?25h'
    printf '\e[?1049l'
}

cursor_show() { printf '\e[?25h'; }
cursor_hide() { printf '\e[?25l'; }

on_resize() { RESIZED=1; }

compute_layout() {
    COLS=$(tput cols 2>/dev/null || echo 80)
    ROWS=$(tput lines 2>/dev/null || echo 24)
    [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
    [[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS=24

    RIGHT_W=38
    (( COLS < 104 )) && RIGHT_W=34
    (( COLS < 92 ))  && RIGHT_W=30

    HEAD_Y=1;  HEAD_H=3
    BODY_Y=$(( HEAD_Y + HEAD_H ))
    FOOT_H=3
    FOOT_Y=$(( ROWS - FOOT_H ))
    BODY_H=$(( FOOT_Y - BODY_Y ))

    FORM_X=1
    FORM_W=$(( COLS - RIGHT_W - 1 ))
    RIGHT_X=$(( COLS - RIGHT_W + 1 ))
    # 13 lignes : panneau d'etat complet (11 informations)
    # 9 lignes  : version compacte, pour garder les raccourcis visibles
    MACH_H=13
    HELP_H=$(( BODY_H - MACH_H ))
    if (( HELP_H < 9 )); then
        MACH_H=9
        HELP_H=$(( BODY_H - MACH_H ))
    fi
    (( HELP_H < 3 )) && { MACH_H=$(( BODY_H - 3 )); HELP_H=3; }

    FORM_ROWS=$(( BODY_H - 2 ))
}

term_too_small() { (( COLS < 76 || ROWS < 20 )); }

#==============================================================================
#  2. TRADUCTIONS
#
#  Toutes les chaines affichees vivent dans des variables L_*, chargees une
#  fois la langue choisie. Les deux blocs se suivent dans le meme ordre pour
#  rester faciles a comparer.
#==============================================================================

UILANG="fr"
CONF_LANG=""
declare -a L_KEYS

load_strings() {
    if [[ $UILANG == en ]]; then
        # ------------------------------------------------------------------ ENGLISH
        L_APP_TITLE="DNS-DHCP AUTO - BIND9 AND KEA DHCP MANAGER"
        L_PANEL_CONFIG="Configuration"
        L_PANEL_STATE="Machine and services"
        L_PANEL_KEYS="Shortcuts"
        L_MODIFIED="* modified"
        L_BTN_APPLY="[ APPLY ]"
        L_BTN_ACTIONS="[ ACTIONS ]"
        L_BTN_DIAG="[ DIAGNOSTICS ]"
        L_BTN_QUIT="[ QUIT ]"
        L_NOTE_CONF="Configuration"
        L_NOTE_LOG="Log file"
        L_BYE="Goodbye."
        L_NONE="none"
        L_M_HOST="Hostname"
        L_M_IP="IP address"
        L_M_OS="System"
        L_M_FW="Firewall"
        L_M_DNS_SVC="BIND9"
        L_M_DNS_BOOT="BIND9 boot"
        L_M_DHCP_SVC="Kea DHCP4"
        L_M_DHCP_BOOT="DHCP boot"
        L_M_P53="Port 53 DNS"
        L_M_P67="Port 67 DHCP"
        L_M_PORTS="Ports 53 / 67"
        L_M_ZONES="Zones/leases"
        L_V_FREE="free"
        L_V_UNKNOWN="unknown"
        L_V_ACTIVE="active"
        L_V_INACTIVE="inactive"
        L_V_NONE="none"
        L_V_INSTALLED="installed"
        L_V_MISSING="not installed"
        L_V_RUNNING="running"
        L_V_STOPPED="stopped"
        L_V_FAILED="failed"
        L_V_ABSENT="absent"
        L_V_ENABLED="enabled"
        L_V_DISABLED="disabled"
        L_V_MASKED="masked"
        L_V_SAVED="saved"
        L_V_NEW="new"
        L_SEC_SERVICES="SERVICES TO MANAGE"
        L_SEC_NET="MACHINE NETWORK"
        L_SEC_DNS="DNS - ZONES"
        L_SEC_DNS_ADV="DNS - ADVANCED SETTINGS"
        L_SEC_DHCP="DHCP - SCOPE"
        L_SEC_DHCP_ADV="DHCP - ADVANCED SETTINGS"
        L_SEC_DDNS="DYNAMIC UPDATES (DDNS)"
        L_SEC_SYS="SYSTEM"
        L_F_DNS_ON="Enable BIND9 (DNS)"
        L_H_DNS_ON="No: the DNS service is stopped and disabled at boot."
        L_F_DHCP_ON="Enable Kea DHCP4"
        L_H_DHCP_ON="No: the DHCP service is stopped and disabled at boot."
        L_F_BOOT="Start at boot"
        L_H_BOOT="Starts the enabled services when the machine boots."
        L_F_IFACE="Network interface"
        L_H_IFACE="Interface the services listen on. Changing it reloads IP and mask."
        L_F_SRVIP="Server IP address"
        L_H_SRVIP="Fixed address of this machine, announced as the DNS server."
        L_F_MASK="Subnet mask"
        L_H_MASK="Example: 255.255.255.0. Used to derive network and reverse zone."
        L_F_GW="Gateway"
        L_H_GW="Default gateway announced to DHCP clients. Empty means none."
        L_F_DOMAIN="Domain name"
        L_H_DOMAIN="Internal domain, for example example.lan. This is the forward zone."
        L_F_NSNAME="DNS server name"
        L_H_NSNAME="Short name of the server inside the zone, for example ns1."
        L_F_ZFWD="Forward zone"
        L_H_ZFWD="Creates the name to address zone for the given domain."
        L_F_ZREV="Reverse zone"
        L_H_ZREV="Creates the address to name zone (PTR) for the local network."
        L_F_REVZONE="Reverse zone name"
        L_H_REVZONE="Derived from the network, for example 1.168.192.in-addr.arpa."
        L_F_ADMIN="Zone contact"
        L_H_ADMIN="Left part of the SOA contact address, without the at sign."
        L_F_RECORDS="DNS records"
        L_H_RECORDS="Enter opens the list: add, edit or remove a host."
        L_F_FWDERS="Forwarders"
        L_H_FWDERS="Servers queried for external names, separated by ;"
        L_F_FWDONLY="Forward only"
        L_H_FWDONLY="Never query the root servers, only the forwarders."
        L_F_RECUR="Recursion"
        L_H_RECUR="Lets the server resolve names it does not host itself."
        L_F_ALLOWQ="Allowed clients"
        L_H_ALLOWQ="Who may query: localhost, localnets, any or CIDR networks."
        L_F_ALLOWX="Allowed transfers"
        L_H_ALLOWX="Who may copy the zones. none is the safe setting."
        L_F_DNSSEC="DNSSEC validation"
        L_H_DNSSEC="Checks answer signatures. Turn off if the network breaks them."
        L_F_LISTEN6="IPv6 listening"
        L_H_LISTEN6="Makes BIND listen on the machine IPv6 addresses."
        L_F_HIDEVER="Hide version"
        L_H_HIDEVER="Reveals neither the BIND version nor the machine name."
        L_F_DNSLOG="Dedicated log"
        L_H_DNSLOG="Writes DNS events into /var/log/named/named.log."
        L_F_TTL="Default TTL"
        L_H_TTL="Lifetime of the answers, in seconds."
        L_F_REFRESH="SOA refresh"
        L_H_REFRESH="Delay before a secondary server rechecks the zone."
        L_F_RETRY="SOA retry"
        L_H_RETRY="Delay before retrying after a failed transfer."
        L_F_EXPIRE="SOA expire"
        L_H_EXPIRE="Time after which a secondary gives the zone up."
        L_F_NEGTTL="Negative TTL"
        L_H_NEGTTL="How long a name does not exist answer stays cached."
        L_F_DIFACE="DHCP interface"
        L_H_DIFACE="Interface the server hands addresses out on."
        L_F_SUBNET="Subnet"
        L_H_SUBNET="Address of the served network, derived from IP and mask."
        L_F_DMASK="DHCP mask"
        L_H_DMASK="Mask announced to the clients, usually the machine one."
        L_F_RSTART="Range start"
        L_H_RSTART="First address handed out. Must stay clear of the reservations."
        L_F_REND="Range end"
        L_H_REND="Last address handed out."
        L_F_ROUTERS="Announced gateway"
        L_H_ROUTERS="The routers option sent to clients. Empty means not sent."
        L_F_DDNS="Announced DNS servers"
        L_H_DDNS="Addresses sent to the clients, separated by ;"
        L_F_DDOMAIN="Announced domain"
        L_H_DDOMAIN="Search suffix sent to the clients."
        L_F_RESERV="Reservations"
        L_H_RESERV="Enter opens the list: one fixed address per MAC address."
        L_F_LEASE="Default lease"
        L_H_LEASE="Lease duration in seconds when the client asks for nothing."
        L_F_MAXLEASE="Maximum lease"
        L_H_MAXLEASE="Longest duration granted, even if the client asks for more."
        L_F_AUTH="Authoritative server"
        L_H_AUTH="Answers no to clients claiming an address from another network."
        L_F_DENY="Deny unknown clients"
        L_H_DENY="Only serves machines that have a reservation. Be careful."
        L_F_BCAST="Broadcast address"
        L_H_BCAST="Derived from network and mask. Empty means not announced."
        L_F_NTP="NTP servers"
        L_H_NTP="Time servers announced to the clients, separated by ;"
        L_F_NEXTSRV="Boot server"
        L_H_NEXTSRV="TFTP server address for PXE boot. Empty means none."
        L_F_BOOTFILE="Boot file"
        L_H_BOOTFILE="Path of the file loaded over PXE, for example pxelinux.0."
        L_F_DDNS_ON="Dynamic updates"
        L_H_DDNS_ON="The kea-dhcp-ddns daemon writes the leases into the DNS zones."
        L_F_DDNSKEY="Key name"
        L_H_DDNSKEY="Name of the key shared between BIND and the DHCP server."
        L_F_DDNSALGO="Algorithm"
        L_H_DDNSALGO="Signature algorithm of the key. hmac-sha256 is fine."
        L_F_FW="Open the firewall"
        L_H_FW="Opens 53 and 67 in ufw for the enabled services."
        L_F_RESOLV="Use this DNS"
        L_H_RESOLV="Points /etc/resolv.conf at 127.0.0.1 and stops systemd-resolved."
        L_F_BACKUP="Back up first"
        L_H_BACKUP="Copies the files in place before replacing them."
        L_F_RESTART="Restart afterwards"
        L_H_RESTART="Applies the wanted service state at the end of the run."
        L_F_UNINST="Uninstall script"
        L_H_UNINST="Writes uninstall-dns-dhcp.sh next to this script."
        L_YESV="YES"
        L_NOV="NO"
        L_YES=" Yes "
        L_NO=" No "
        L_EMPTY="empty"
        L_UNSET="unset"
        L_LIST_COUNT="[ %s entries ]"
        L_ST_SECTION="Enter or Space: fold or unfold this section."
        L_ST_APPLY="Checks then writes the whole configuration and restarts the services."
        L_ST_ACTIONS="Services, zones, leases, logs, backups, removal."
        L_ST_DIAG="Detailed state: services, ports, checks, latest errors."
        L_ST_QUIT="Leaves the manager. The configuration can be saved."
        L_ST_THEME_LIGHT="Light theme."
        L_ST_THEME_DARK="Dark theme."
        L_ST_REFRESHING="Reading machine state..."
        L_ST_REFRESHED="Machine state refreshed."
        L_ANY_KEY="Press any key to continue"
        L_EDIT_HELP="Enter confirms, Esc cancels, Ctrl+U clears"
        L_INVALID_T="Rejected value"
        L_MENU_HELP="Arrows, Enter to choose, Esc to go back"
        L_MENU_PICK="Arrows then Enter"
        L_MENU_EMPTY="Nothing to show."
        L_VIEW_HELP="line %s of %s - arrows to scroll, q to close"
        L_VIEW_EMPTY="(no output)"
        L_TOO_SMALL="Terminal too small (%sx%s). Minimum is 76x20."
        L_TOO_SMALL_CLI="Please enlarge the terminal window (minimum 76x20)."
        L_CMD_RC="(no output, exit code %s)"
        L_ERR_IP="An IPv4 address is expected, for example 192.168.1.10."
        L_ERR_IP6="An IPv6 address is expected."
        L_ERR_MASK="Invalid mask. Example: 255.255.255.0."
        L_ERR_HOST="Invalid short name: letters, digits and hyphens only."
        L_ERR_DOMAIN="Invalid domain name. Example: example.lan."
        L_ERR_ZONE="Invalid zone name."
        L_ERR_MAIL="Invalid contact: left part only, without the at sign."
        L_ERR_IPLIST="A list of IPv4 addresses separated by ; is expected"
        L_ERR_ACL="Expected: localhost, localnets, any, none or CIDR networks."
        L_ERR_MAC="A MAC address is expected, for example 00:11:22:33:44:55."
        L_ERR_NUM="A whole number is expected."
        L_ERR_NUM_RANGE="Value out of range."
        L_ERR_PATH="Invalid path."
        L_ERR_TARGET="Invalid target: host name or full name ending with a dot."
        L_ERR_MX="Expected: priority then target, for example 10 mail.example.lan."
        L_ERR_SRV="Expected: priority weight port target."
        L_ERR_TXT="A non-empty text without quotes is expected."
        L_ERR_SEP="The ; and | characters are not allowed in a value."
        L_ERR_NOSVC="Enable at least one of the two services before applying."
        L_ERR_NOZONE="DNS is enabled but no zone is requested."
        L_ERR_NOFWD="Forward only requested without any forwarder."
        L_ERR_NOIFACE="No interface chosen for the DHCP service."
        L_ERR_SUBNET="This is not a network address. Expected: %s"
        L_ERR_RANGE_OUT="This address falls outside the served subnet."
        L_ERR_RANGE_ORDER="The range start must come before the end."
        L_ERR_RANGE_SELF="The range covers the address of the server itself."
        L_ERR_LEASE="The default lease exceeds the maximum lease."
        L_ERR_RESERV="Invalid reservation: %s"
        L_ERR_RES_NET="This address does not belong to the served subnet."
        L_LIST_ADD="+ Add"
        L_LIST_HELP="Enter edits, a adds, s deletes, Esc closes"
        L_LIST_DEL_T="Delete"
        L_LIST_DEL_Q=$'Delete this entry?\n\n  %s'
        L_RECORDS_T="DNS records"
        L_REC_T="Record"
        L_REC_NAME="Name inside the zone:"
        L_REC_NAME_H="Short name, without the domain. @ means the zone itself."
        L_REC_TYPE="Record type"
        L_REC_VALUE="Value"
        L_RH_A="IPv4 address, for example 192.168.1.20."
        L_RH_AAAA="IPv6 address."
        L_RH_CNAME="Target name. End with a dot for a fully qualified name."
        L_RH_MX="Priority then server, for example: 10 mail"
        L_RH_TXT="Free text, without quotes."
        L_RH_SRV="priority weight port target, for example: 0 5 5060 sip"
        L_RH_NS="Name server name, ending with a dot."
        L_RESERV_T="DHCP reservations"
        L_RES_T="Reservation"
        L_RES_NAME="Machine name:"
        L_RES_NAME_H="Short name, also used as an A record in the zone."
        L_RES_MAC="MAC address:"
        L_RES_MAC_H="Six bytes separated by : or by -"
        L_RES_IP="Fixed address:"
        L_RES_IP_H="Address always given to this network card."
        L_RES_INRANGE_T="Address inside the range"
        L_RES_INRANGE_Q=$'This address sits inside the handed-out range.\nIt may end up assigned twice.\n\nKeep it anyway?'
        L_JOB_INSTALL="Package installation"
        L_JOB_APPLY="Configuration apply"
        L_JOB_REMOVE="Removal"
        L_S_APT_LOCK="Waiting for apt to be free"
        L_S_APT_UPDATE="Updating the package list"
        L_S_APT_DNS="Installing BIND9"
        L_S_APT_DNS_SKIP="BIND9 already installed"
        L_S_APT_DHCP="Installing Kea DHCP4"
        L_S_APT_DHCP_SKIP="Kea DHCP4 already installed"
        L_S_DONE="Done"
        L_E_APT_UPDATE="Updating the package list failed."
        L_E_APT_DNS="Installing BIND9 failed."
        L_E_APT_DHCP="Installing Kea DHCP4 failed."
        L_S_BACKUP="Backing up the files in place"
        L_S_BACKUP_SKIP="Backup not requested"
        L_S_SAVECONF="Saving the configuration"
        L_S_DDNSKEY="Dynamic update key"
        L_S_BIND_OPT="BIND9 options"
        L_S_BIND_LOCAL="Zone declarations"
        L_S_ZONES="Writing the zone files"
        L_S_CHECK_DNS="Checking the DNS configuration"
        L_S_DNS_SKIP="DNS disabled"
        L_S_DHCP_CONF="Kea DHCP4 configuration"
        L_S_DHCP_DEF="Dynamic update daemon"
        L_S_CHECK_DHCP="Checking the DHCP configuration"
        L_S_DHCP_SKIP="DHCP disabled"
        L_S_RESOLV="Machine name resolution"
        L_S_FIREWALL="Opening the firewall"
        L_S_SERVICES="Applying the service state"
        L_S_SERVICES_SKIP="Services left as they are"
        L_S_UNINST="Writing the uninstall script"
        L_E_BACKUP="Backing up the files failed."
        L_E_SAVECONF="Saving into /etc/dns-dhcp-auto failed."
        L_E_DDNSKEY="Creating the update key failed."
        L_E_BIND_OPT="Writing the BIND9 options failed."
        L_E_BIND_LOCAL="Writing the zones into named.conf.local failed."
        L_E_ZONES="Writing the zone files failed."
        L_E_CHECK_DNS="The DNS configuration is rejected by named-checkconf."
        L_E_DHCP_CONF="Writing kea-dhcp4.conf failed."
        L_E_DHCP_DEF="Writing kea-dhcp-ddns.conf failed."
        L_E_CHECK_DHCP="The DHCP configuration is rejected by kea-dhcp4 -t."
        L_E_RESOLV="Changing /etc/resolv.conf failed."
        L_E_FIREWALL="Opening the firewall failed."
        L_E_SERVICES="A service did not start. See the diagnostics."
        L_E_UNINST="Writing the uninstall script failed."
        L_S_R_STOP="Stopping the services"
        L_S_R_FW="Closing the ports"
        L_S_R_FILES="Removing the generated files"
        L_S_R_PKG="Purging the packages"
        L_S_R_PKG_SKIP="Packages kept"
        L_S_R_CONF="Removing the saved state"
        L_E_R_STOP="Stopping the services failed."
        L_E_R_FILES="Removing the files failed."
        L_E_R_PKG="Purging the packages failed."
        L_ANIM_INST_TITLE="Installing packages"
        L_ANIM_APPLY_TITLE="Applying the configuration"
        L_ANIM_REM_TITLE="Removing"
        L_ANIM_WORK_TITLE="Work in progress"
        L_ANIM_FAIL_PHASE="FAILED"
        L_ANIM_LOG="Full log: %s"
        L_FAIL_T="Failure"
        L_FAIL_LOGTAIL="Last lines of the log:"
        L_FAIL_NONE="none"
        L_FAIL_LOG="Full log: %s"
        L_ACTIONS_T="Actions"
        L_A_APPLY="Apply the configuration"
        L_A_INSTALL="Install the missing packages"
        L_A_CHECK="Check the configuration files"
        L_A_DIAG="Full diagnostics"
        L_A_DNS_START="Start BIND9"
        L_A_DNS_STOP="Stop BIND9"
        L_A_DNS_RESTART="Restart BIND9"
        L_A_DNS_RELOAD="Reload the DNS zones"
        L_A_DNS_BOOT_ON="Enable BIND9 at boot"
        L_A_DNS_BOOT_OFF="Disable BIND9 at boot"
        L_A_DHCP_START="Start Kea DHCP4"
        L_A_DHCP_STOP="Stop Kea DHCP4"
        L_A_DHCP_RESTART="Restart Kea DHCP4"
        L_A_DHCP_BOOT_ON="Enable Kea DHCP4 at boot"
        L_A_DHCP_BOOT_OFF="Disable Kea DHCP4 at boot"
        L_A_LEASES="Show the DHCP leases"
        L_A_RECORDS="Manage the DNS records"
        L_A_RESERV="Manage the DHCP reservations"
        L_A_DIG="Test a name resolution"
        L_A_LOGS_DNS="BIND9 log"
        L_A_LOGS_DHCP="DHCP server log"
        L_A_FIREWALL="Firewall"
        L_A_BACKUP="Back up now"
        L_A_RESTORE="Restore a backup"
        L_A_DERIVE="Recompute from the network"
        L_A_RESET="Reset to the default values"
        L_A_REMOVE="Uninstall BIND9 and Kea DHCP4"
        L_SVC_T="Service"
        L_SVC_ABSENT=$'Unit %s does not exist on this machine.\nIs the package installed?'
        L_SVC_OK="%s: %s done."
        L_SVC_KO="%s: the command failed."
        L_SVC_FAIL_T="Service failure"
        L_BOOT_OK="%s: %s at boot."
        L_LEASES_T="DHCP leases"
        L_LEASES_NONE="No lease recorded yet."
        L_LEASE_ACTIVE="active"
        L_LEASE_FREE="released"
        L_DIG_T="Resolution test"
        L_DIG_ASK="Name to resolve:"
        L_DIG_HINT="The query goes to the local server (127.0.0.1)."
        L_DIG_MISSING=$'The dig command is missing.\nInstall bind9-dnsutils or dnsutils.'
        L_DIAG_T="Diagnostics"
        L_DIAG_HEAD="MACHINE STATE"
        L_DIAG_SVC="SERVICES (package / state / boot)"
        L_DIAG_UNITS="systemd units"
        L_DIAG_PORTS="LISTENING PORTS"
        L_DIAG_NOPORT="No service is listening on 53 or 67."
        L_DIAG_CHECK_DNS="DNS CONFIGURATION CHECK"
        L_DIAG_CHECK_DHCP="DHCP CONFIGURATION CHECK"
        L_DIAG_OK="Configuration accepted."
        L_DIAG_RESOLV="LOCAL RESOLUTION"
        L_DIAG_LEASES="DHCP LEASES"
        L_DIAG_LEASE_N="%s lease(s) in the lease file."
        L_DIAG_LOGTAIL="LAST LINES OF THE LOG"
        L_CHECK_T="Check"
        L_CHECK_RC="Exit code: %s"
        L_CHECK_NO_BIND="named-checkconf is missing: BIND9 is not installed."
        L_CHECK_NO_DHCP="kea-dhcp4 is missing: Kea is not installed."
        L_CHECK_NOTHING="No enabled service: nothing to check."
        L_FW_T="Firewall"
        L_FW_OPEN="Open the ports of the enabled services"
        L_FW_CLOSE="Close the DNS and DHCP ports"
        L_FW_STATUS="Show the firewall state"
        L_FW_NO_UFW=$'ufw is not installed on this machine.\nRules have to be added by hand.'
        L_FW_NOPORT="No enabled service: no port to open."
        L_FW_CLOSE_Q=$'Close 53/tcp, 53/udp, 67/udp and 68/udp?\n\nClients will no longer reach these services.'
        L_BACKUP_T="Backup"
        L_BACKUP_KO="The backup failed."
        L_RESTORE_T="Restore"
        L_RESTORE_NONE="No backup available."
        L_RESTORE_Q=$'Restore backup %s?\n\nThe files in place will be replaced.'
        L_RESTORE_OK=$'Backup restored.\nRestart the services to pick it up.'
        L_RESTORE_KO="The restore is incomplete. See the log."
        L_APPLY_T="Apply"
        L_WARN_OPEN_T="Open resolver"
        L_WARN_OPEN_B=$'Recursion is on and any client is allowed to query.\nThis machine becomes an open resolver: it can be used\nto amplify attacks against third parties.\n\nApply anyway?'
        L_FORM_KO_T="Incomplete configuration"
        L_SUM_HEAD="Here is what is about to be written:"
        L_SUM_DNS="DNS"
        L_SUM_DNS_OFF="DNS: disabled, service stopped"
        L_SUM_REV="Reverse zone"
        L_SUM_FWD="Forwarders"
        L_SUM_RECS="Records"
        L_SUM_DHCP="DHCP"
        L_SUM_DHCP_OFF="DHCP: disabled, service stopped"
        L_SUM_RANGE="Handed-out range"
        L_SUM_RES="Reservations"
        L_SUM_BACKUP="The files in place will be backed up."
        L_SUM_RESTART="The services will be restarted."
        L_SUM_RESOLV="/etc/resolv.conf will point at this server."
        L_SUM_ASK="Continue?"
        L_REP_T="Configuration applied"
        L_REP_DONE="The configuration has been written and applied."
        L_REP_HEAD="State after apply:"
        L_REP_ZONEDIR="Zone files"
        L_REP_DOMAIN="Domain"
        L_REP_RANGE="DHCP range"
        L_REP_CONF="Configuration"
        L_REP_LOG="Log file"
        L_REP_UNINST="Uninstall"
        L_REP_WARN="A service is not running: open the diagnostics (key d)."
        L_INSTALL_T="Installation"
        L_INSTALL_OK="The requested packages are installed."
        L_INSTALL_NOTHING="Nothing to install: everything is already there."
        L_DHCP_MISSING_T="Kea DHCP4 unavailable"
        L_DHCP_MISSING_B=$'The kea-dhcp4-server package is not in this\ndistribution repositories.\n\nThe DNS side stays fully usable. For DHCP, enable the\nrepository that carries Kea, or turn the DHCP part off.'
        L_DERIVE_T="Recompute"
        L_DERIVE_Q=$'Read the machine address, mask and gateway again\nand recompute the derived values?\n\nHand-typed values will be replaced.'
        L_DERIVE_OK="Values recomputed from the machine network."
        L_RESET_T="Default values"
        L_RESET_Q=$'Reset the whole form to its default values?\n\nThe files already in place are left alone.'
        L_RESET_OK="Form reset."
        L_REMOVE_T="Uninstall"
        L_REMOVE_Q=$'Remove the BIND9 and Kea DHCP4 configuration?\n\nThe services will be stopped and disabled.\nThe backups are kept.'
        L_REMOVE_PURGE_Q="Also purge the bind9 and kea-dhcp4-server packages?"
        L_REMOVE_DONE="BIND9 and Kea DHCP4 have been removed from this machine."
        L_SAVE_T="Saving"
        L_SAVE_OK="Configuration saved into %s"
        L_SAVE_KO="The configuration could not be written."
        L_QUIT_T="Quit"
        L_QUIT_ASK="Leave the manager?"
        L_QUIT_DIRTY=$'The configuration was changed\nwithout being saved.'
        L_C3_SAVE=" Save "
        L_C3_QUIT=" Quit "
        L_C3_CANCEL=" Cancel "
        L_WELCOME_T="Welcome"
        L_WELCOME_B=$'No saved configuration was found: the fields are\npre-filled from the machine network.\n\nWalk through the sections, adjust what needs it,\nthen choose APPLY. Nothing is written before that.\n\nKey a: actions menu      Key d: diagnostics'
        L_CONF_HEAD="dns-dhcp-auto configuration - do not edit while running"
        L_CLI_NOCONF="No saved configuration: run the script without any option."
        L_CLI_APPLIED="Configuration applied."
        L_KEYS=(
            "Up/Down|move"
            "Enter|edit / confirm"
            "Space|yes / no"
            "Left/Right|fold / adjust"
            "a|actions menu"
            "d|diagnostics"
            "s|save"
            "r|refresh state"
            "t|light/dark theme"
            "q|quit"
        )
    else
        # ----------------------------------------------------------------- FRANCAIS
        L_APP_TITLE="DNS-DHCP AUTO - GESTION BIND9 ET KEA DHCP"
        L_PANEL_CONFIG="Configuration"
        L_PANEL_STATE="Machine et services"
        L_PANEL_KEYS="Raccourcis"
        L_MODIFIED="* modifie"
        L_BTN_APPLY="[ APPLIQUER ]"
        L_BTN_ACTIONS="[ ACTIONS ]"
        L_BTN_DIAG="[ DIAGNOSTIC ]"
        L_BTN_QUIT="[ QUITTER ]"
        L_NOTE_CONF="Configuration"
        L_NOTE_LOG="Journal"
        L_BYE="A bientot."
        L_NONE="aucun"
        L_M_HOST="Nom d'hote"
        L_M_IP="Adresse IP"
        L_M_OS="Systeme"
        L_M_FW="Pare-feu"
        L_M_DNS_SVC="BIND9"
        L_M_DNS_BOOT="BIND9 boot"
        L_M_DHCP_SVC="Kea DHCP4"
        L_M_DHCP_BOOT="DHCP boot"
        L_M_P53="Port 53 DNS"
        L_M_P67="Port 67 DHCP"
        L_M_PORTS="Ports 53 / 67"
        L_M_ZONES="Zones/baux"
        L_V_FREE="libre"
        L_V_UNKNOWN="inconnu"
        L_V_ACTIVE="actif"
        L_V_INACTIVE="inactif"
        L_V_NONE="aucun"
        L_V_INSTALLED="installe"
        L_V_MISSING="absent"
        L_V_RUNNING="demarre"
        L_V_STOPPED="arrete"
        L_V_FAILED="en echec"
        L_V_ABSENT="absent"
        L_V_ENABLED="active"
        L_V_DISABLED="desactive"
        L_V_MASKED="masque"
        L_V_SAVED="enregistree"
        L_V_NEW="nouvelle"
        L_SEC_SERVICES="SERVICES A GERER"
        L_SEC_NET="RESEAU DE LA MACHINE"
        L_SEC_DNS="DNS - ZONES"
        L_SEC_DNS_ADV="DNS - REGLAGES AVANCES"
        L_SEC_DHCP="DHCP - ETENDUE"
        L_SEC_DHCP_ADV="DHCP - REGLAGES AVANCES"
        L_SEC_DDNS="MISE A JOUR DYNAMIQUE (DDNS)"
        L_SEC_SYS="SYSTEME"
        L_F_DNS_ON="Activer BIND9 (DNS)"
        L_H_DNS_ON="Non : le service DNS est arrete et desactive au demarrage."
        L_F_DHCP_ON="Activer Kea DHCP4"
        L_H_DHCP_ON="Non : le service DHCP est arrete et desactive au demarrage."
        L_F_BOOT="Demarrage automatique"
        L_H_BOOT="Lance les services actives au demarrage de la machine."
        L_F_IFACE="Interface reseau"
        L_H_IFACE="Interface d'ecoute des services. Changer recharge IP et masque."
        L_F_SRVIP="Adresse IP du serveur"
        L_H_SRVIP="Adresse fixe de cette machine, annoncee comme serveur DNS."
        L_F_MASK="Masque de sous-reseau"
        L_H_MASK="Exemple : 255.255.255.0. Sert a deduire reseau et zone inverse."
        L_F_GW="Passerelle"
        L_H_GW="Passerelle par defaut annoncee aux clients DHCP. Vide = aucune."
        L_F_DOMAIN="Nom de domaine"
        L_H_DOMAIN="Domaine interne, par exemple exemple.lan. C'est la zone directe."
        L_F_NSNAME="Nom du serveur DNS"
        L_H_NSNAME="Nom court du serveur dans la zone, par exemple ns1."
        L_F_ZFWD="Zone directe"
        L_H_ZFWD="Cree la zone nom vers adresse pour le domaine indique."
        L_F_ZREV="Zone inverse"
        L_H_ZREV="Cree la zone adresse vers nom (PTR) pour le reseau local."
        L_F_REVZONE="Nom de la zone inverse"
        L_H_REVZONE="Calcule depuis le reseau, par exemple 1.168.192.in-addr.arpa."
        L_F_ADMIN="Contact de la zone"
        L_H_ADMIN="Partie gauche de l'adresse de contact du SOA, sans arobase."
        L_F_RECORDS="Enregistrements DNS"
        L_H_RECORDS="Entree ouvre la liste : ajouter, modifier ou supprimer un hote."
        L_F_FWDERS="Redirecteurs"
        L_H_FWDERS="Serveurs interroges pour les noms externes, separes par ;"
        L_F_FWDONLY="Redirection seule"
        L_H_FWDONLY="N'interroge jamais les serveurs racine, seulement les redirecteurs."
        L_F_RECUR="Recursion"
        L_H_RECUR="Autorise le serveur a resoudre les noms qu'il n'heberge pas."
        L_F_ALLOWQ="Clients autorises"
        L_H_ALLOWQ="Qui peut interroger : localhost, localnets, any ou reseaux en CIDR."
        L_F_ALLOWX="Transferts autorises"
        L_H_ALLOWX="Qui peut copier les zones. none est le reglage sur."
        L_F_DNSSEC="Validation DNSSEC"
        L_H_DNSSEC="Verifie les signatures des reponses. A couper si le reseau les casse."
        L_F_LISTEN6="Ecoute IPv6"
        L_H_LISTEN6="Fait ecouter BIND sur les adresses IPv6 de la machine."
        L_F_HIDEVER="Masquer la version"
        L_H_HIDEVER="Ne revele ni la version de BIND ni le nom de la machine."
        L_F_DNSLOG="Journal dedie"
        L_H_DNSLOG="Ecrit les evenements DNS dans /var/log/named/named.log."
        L_F_TTL="TTL par defaut"
        L_H_TTL="Duree de vie des reponses, en secondes."
        L_F_REFRESH="SOA refresh"
        L_H_REFRESH="Delai avant qu'un serveur secondaire recontrole la zone."
        L_F_RETRY="SOA retry"
        L_H_RETRY="Delai avant un nouvel essai apres un echec de transfert."
        L_F_EXPIRE="SOA expire"
        L_H_EXPIRE="Duree au bout de laquelle un secondaire abandonne la zone."
        L_F_NEGTTL="TTL negatif"
        L_H_NEGTTL="Duree de mise en cache des reponses nom inexistant."
        L_F_DIFACE="Interface DHCP"
        L_H_DIFACE="Interface sur laquelle le serveur distribue les adresses."
        L_F_SUBNET="Sous-reseau"
        L_H_SUBNET="Adresse du reseau desservi, calculee depuis IP et masque."
        L_F_DMASK="Masque DHCP"
        L_H_DMASK="Masque annonce aux clients, en general celui de la machine."
        L_F_RSTART="Debut de plage"
        L_H_RSTART="Premiere adresse distribuee. Doit rester hors des reservations."
        L_F_REND="Fin de plage"
        L_H_REND="Derniere adresse distribuee."
        L_F_ROUTERS="Passerelle annoncee"
        L_H_ROUTERS="Option routers envoyee aux clients. Vide = non envoyee."
        L_F_DDNS="Serveurs DNS annonces"
        L_H_DDNS="Adresses envoyees aux clients, separees par ;"
        L_F_DDOMAIN="Domaine annonce"
        L_H_DDOMAIN="Suffixe de recherche envoye aux clients."
        L_F_RESERV="Reservations"
        L_H_RESERV="Entree ouvre la liste : une adresse fixe par adresse MAC."
        L_F_LEASE="Bail par defaut"
        L_H_LEASE="Duree d'un bail en secondes quand le client ne demande rien."
        L_F_MAXLEASE="Bail maximum"
        L_H_MAXLEASE="Duree maximale accordee, meme si le client en demande plus."
        L_F_AUTH="Serveur autoritaire"
        L_H_AUTH="Repond non aux clients qui reclament une adresse d'un autre reseau."
        L_F_DENY="Refuser les inconnus"
        L_H_DENY="Ne sert que les machines ayant une reservation. Prudence."
        L_F_BCAST="Adresse de diffusion"
        L_H_BCAST="Calculee depuis reseau et masque. Vide = non annoncee."
        L_F_NTP="Serveurs NTP"
        L_H_NTP="Serveurs de temps annonces aux clients, separes par ;"
        L_F_NEXTSRV="Serveur de demarrage"
        L_H_NEXTSRV="Adresse du serveur TFTP pour un demarrage PXE. Vide = aucun."
        L_F_BOOTFILE="Fichier de demarrage"
        L_H_BOOTFILE="Chemin du fichier charge en PXE, par exemple pxelinux.0."
        L_F_DDNS_ON="Mise a jour dynamique"
        L_H_DDNS_ON="Le demon kea-dhcp-ddns inscrit les baux dans les zones DNS."
        L_F_DDNSKEY="Nom de la cle"
        L_H_DDNSKEY="Nom de la cle partagee entre BIND et le serveur DHCP."
        L_F_DDNSALGO="Algorithme"
        L_H_DDNSALGO="Algorithme de signature de la cle. hmac-sha256 convient."
        L_F_FW="Ouvrir le pare-feu"
        L_H_FW="Ouvre 53 et 67 dans ufw pour les services actives."
        L_F_RESOLV="Utiliser ce DNS"
        L_H_RESOLV="Pointe /etc/resolv.conf sur 127.0.0.1 et coupe systemd-resolved."
        L_F_BACKUP="Sauvegarder avant"
        L_H_BACKUP="Copie les fichiers en place avant de les remplacer."
        L_F_RESTART="Redemarrer apres"
        L_H_RESTART="Applique l'etat voulu aux services a la fin du traitement."
        L_F_UNINST="Script de suppression"
        L_H_UNINST="Ecrit uninstall-dns-dhcp.sh a cote de ce script."
        L_YESV="OUI"
        L_NOV="NON"
        L_YES=" Oui "
        L_NO=" Non "
        L_EMPTY="vide"
        L_UNSET="non defini"
        L_LIST_COUNT="[ %s entree(s) ]"
        L_ST_SECTION="Entree ou Espace : plier ou deplier cette section."
        L_ST_APPLY="Verifie puis ecrit toute la configuration et relance les services."
        L_ST_ACTIONS="Services, zones, baux, journaux, sauvegardes, suppression."
        L_ST_DIAG="Etat detaille : services, ports, controles, dernieres erreurs."
        L_ST_QUIT="Quitte le gestionnaire. La configuration peut etre enregistree."
        L_ST_THEME_LIGHT="Theme clair."
        L_ST_THEME_DARK="Theme sombre."
        L_ST_REFRESHING="Lecture de l'etat de la machine..."
        L_ST_REFRESHED="Etat de la machine actualise."
        L_ANY_KEY="Une touche pour continuer"
        L_EDIT_HELP="Entree valide, Echap annule, Ctrl+U efface"
        L_INVALID_T="Valeur refusee"
        L_MENU_HELP="Fleches, Entree pour choisir, Echap pour revenir"
        L_MENU_PICK="Fleches puis Entree"
        L_MENU_EMPTY="Rien a afficher."
        L_VIEW_HELP="ligne %s sur %s - fleches pour defiler, q pour fermer"
        L_VIEW_EMPTY="(aucune sortie)"
        L_TOO_SMALL="Terminal trop petit (%sx%s). Minimum 76x20."
        L_TOO_SMALL_CLI="Agrandissez la fenetre du terminal (minimum 76x20)."
        L_CMD_RC="(aucune sortie, code de retour %s)"
        L_ERR_IP="Adresse IPv4 attendue, par exemple 192.168.1.10."
        L_ERR_IP6="Adresse IPv6 attendue."
        L_ERR_MASK="Masque invalide. Exemple : 255.255.255.0."
        L_ERR_HOST="Nom court invalide : lettres, chiffres et tirets uniquement."
        L_ERR_DOMAIN="Nom de domaine invalide. Exemple : exemple.lan."
        L_ERR_ZONE="Nom de zone invalide."
        L_ERR_MAIL="Contact invalide : partie gauche seulement, sans arobase."
        L_ERR_IPLIST="Liste d'adresses IPv4 attendue, separees par ;"
        L_ERR_ACL="Attendu : localhost, localnets, any, none ou reseaux en CIDR."
        L_ERR_MAC="Adresse MAC attendue, par exemple 00:11:22:33:44:55."
        L_ERR_NUM="Nombre entier attendu."
        L_ERR_NUM_RANGE="Valeur hors limites."
        L_ERR_PATH="Chemin invalide."
        L_ERR_TARGET="Cible invalide : nom d'hote ou nom complet termine par un point."
        L_ERR_MX="Attendu : priorite puis cible, par exemple 10 mail.exemple.lan."
        L_ERR_SRV="Attendu : priorite poids port cible."
        L_ERR_TXT="Texte non vide et sans guillemet attendu."
        L_ERR_SEP="Les caracteres ; et | sont interdits dans une valeur."
        L_ERR_NOSVC="Activez au moins un des deux services avant d'appliquer."
        L_ERR_NOZONE="Le DNS est actif mais aucune zone n'est demandee."
        L_ERR_NOFWD="Redirection seule demandee sans aucun redirecteur."
        L_ERR_NOIFACE="Aucune interface choisie pour le service DHCP."
        L_ERR_SUBNET="Ce n'est pas une adresse de reseau. Attendu : %s"
        L_ERR_RANGE_OUT="Cette adresse est en dehors du sous-reseau desservi."
        L_ERR_RANGE_ORDER="Le debut de plage doit preceder la fin."
        L_ERR_RANGE_SELF="La plage englobe l'adresse du serveur lui-meme."
        L_ERR_LEASE="Le bail par defaut depasse le bail maximum."
        L_ERR_RESERV="Reservation invalide : %s"
        L_ERR_RES_NET="Cette adresse n'appartient pas au sous-reseau desservi."
        L_LIST_ADD="+ Ajouter"
        L_LIST_HELP="Entree modifie, a ajoute, s supprime, Echap ferme"
        L_LIST_DEL_T="Supprimer"
        L_LIST_DEL_Q=$'Supprimer cette entree ?\n\n  %s'
        L_RECORDS_T="Enregistrements DNS"
        L_REC_T="Enregistrement"
        L_REC_NAME="Nom dans la zone :"
        L_REC_NAME_H="Nom court, sans le domaine. @ designe la zone elle-meme."
        L_REC_TYPE="Type d'enregistrement"
        L_REC_VALUE="Valeur"
        L_RH_A="Adresse IPv4, par exemple 192.168.1.20."
        L_RH_AAAA="Adresse IPv6."
        L_RH_CNAME="Nom vise. Terminez par un point pour un nom complet."
        L_RH_MX="Priorite puis serveur, par exemple : 10 mail"
        L_RH_TXT="Texte libre, sans guillemet."
        L_RH_SRV="priorite poids port cible, par exemple : 0 5 5060 sip"
        L_RH_NS="Nom du serveur de noms, termine par un point."
        L_RESERV_T="Reservations DHCP"
        L_RES_T="Reservation"
        L_RES_NAME="Nom de la machine :"
        L_RES_NAME_H="Nom court, il sert aussi d'enregistrement A dans la zone."
        L_RES_MAC="Adresse MAC :"
        L_RES_MAC_H="Six octets separes par : ou par -"
        L_RES_IP="Adresse fixe :"
        L_RES_IP_H="Adresse toujours attribuee a cette carte reseau."
        L_RES_INRANGE_T="Adresse dans la plage"
        L_RES_INRANGE_Q=$'Cette adresse est dans la plage distribuee.\nElle risque d\'etre attribuee deux fois.\n\nLa garder quand meme ?'
        L_JOB_INSTALL="Installation des paquets"
        L_JOB_APPLY="Application de la configuration"
        L_JOB_REMOVE="Suppression"
        L_S_APT_LOCK="Attente de la liberation d'apt"
        L_S_APT_UPDATE="Mise a jour de la liste des paquets"
        L_S_APT_DNS="Installation de BIND9"
        L_S_APT_DNS_SKIP="BIND9 deja installe"
        L_S_APT_DHCP="Installation de Kea DHCP4"
        L_S_APT_DHCP_SKIP="Kea DHCP4 deja installe"
        L_S_DONE="Termine"
        L_E_APT_UPDATE="La mise a jour de la liste des paquets a echoue."
        L_E_APT_DNS="L'installation de BIND9 a echoue."
        L_E_APT_DHCP="L'installation de Kea DHCP4 a echoue."
        L_S_BACKUP="Sauvegarde des fichiers en place"
        L_S_BACKUP_SKIP="Sauvegarde non demandee"
        L_S_SAVECONF="Enregistrement de la configuration"
        L_S_DDNSKEY="Cle de mise a jour dynamique"
        L_S_BIND_OPT="Options de BIND9"
        L_S_BIND_LOCAL="Declaration des zones"
        L_S_ZONES="Ecriture des fichiers de zone"
        L_S_CHECK_DNS="Controle de la configuration DNS"
        L_S_DNS_SKIP="DNS desactive"
        L_S_DHCP_CONF="Configuration de Kea DHCP4"
        L_S_DHCP_DEF="Demon de mise a jour dynamique"
        L_S_CHECK_DHCP="Controle de la configuration DHCP"
        L_S_DHCP_SKIP="DHCP desactive"
        L_S_RESOLV="Resolution de noms de la machine"
        L_S_FIREWALL="Ouverture du pare-feu"
        L_S_SERVICES="Application de l'etat des services"
        L_S_SERVICES_SKIP="Services laisses en l'etat"
        L_S_UNINST="Ecriture du script de suppression"
        L_E_BACKUP="La sauvegarde des fichiers a echoue."
        L_E_SAVECONF="L'enregistrement dans /etc/dns-dhcp-auto a echoue."
        L_E_DDNSKEY="La creation de la cle de mise a jour a echoue."
        L_E_BIND_OPT="L'ecriture des options de BIND9 a echoue."
        L_E_BIND_LOCAL="L'ecriture des zones dans named.conf.local a echoue."
        L_E_ZONES="L'ecriture des fichiers de zone a echoue."
        L_E_CHECK_DNS="La configuration DNS est refusee par named-checkconf."
        L_E_DHCP_CONF="L'ecriture de kea-dhcp4.conf a echoue."
        L_E_DHCP_DEF="L'ecriture de kea-dhcp-ddns.conf a echoue."
        L_E_CHECK_DHCP="La configuration DHCP est refusee par kea-dhcp4 -t."
        L_E_RESOLV="La modification de /etc/resolv.conf a echoue."
        L_E_FIREWALL="L'ouverture du pare-feu a echoue."
        L_E_SERVICES="Un service n'a pas demarre. Voir le diagnostic."
        L_E_UNINST="L'ecriture du script de suppression a echoue."
        L_S_R_STOP="Arret des services"
        L_S_R_FW="Fermeture des ports"
        L_S_R_FILES="Suppression des fichiers generes"
        L_S_R_PKG="Purge des paquets"
        L_S_R_PKG_SKIP="Paquets conserves"
        L_S_R_CONF="Suppression de l'etat enregistre"
        L_E_R_STOP="L'arret des services a echoue."
        L_E_R_FILES="La suppression des fichiers a echoue."
        L_E_R_PKG="La purge des paquets a echoue."
        L_ANIM_INST_TITLE="Installation des paquets"
        L_ANIM_APPLY_TITLE="Application de la configuration"
        L_ANIM_REM_TITLE="Suppression"
        L_ANIM_WORK_TITLE="Traitement en cours"
        L_ANIM_FAIL_PHASE="ECHEC"
        L_ANIM_LOG="Journal complet : %s"
        L_FAIL_T="Echec"
        L_FAIL_LOGTAIL="Dernieres lignes du journal :"
        L_FAIL_NONE="aucune"
        L_FAIL_LOG="Journal complet : %s"
        L_ACTIONS_T="Actions"
        L_A_APPLY="Appliquer la configuration"
        L_A_INSTALL="Installer les paquets manquants"
        L_A_CHECK="Verifier les fichiers de configuration"
        L_A_DIAG="Diagnostic complet"
        L_A_DNS_START="Demarrer BIND9"
        L_A_DNS_STOP="Arreter BIND9"
        L_A_DNS_RESTART="Redemarrer BIND9"
        L_A_DNS_RELOAD="Recharger les zones DNS"
        L_A_DNS_BOOT_ON="Activer BIND9 au demarrage"
        L_A_DNS_BOOT_OFF="Desactiver BIND9 au demarrage"
        L_A_DHCP_START="Demarrer Kea DHCP4"
        L_A_DHCP_STOP="Arreter Kea DHCP4"
        L_A_DHCP_RESTART="Redemarrer Kea DHCP4"
        L_A_DHCP_BOOT_ON="Activer Kea DHCP4 au demarrage"
        L_A_DHCP_BOOT_OFF="Desactiver Kea DHCP4 au demarrage"
        L_A_LEASES="Voir les baux DHCP"
        L_A_RECORDS="Gerer les enregistrements DNS"
        L_A_RESERV="Gerer les reservations DHCP"
        L_A_DIG="Tester une resolution de nom"
        L_A_LOGS_DNS="Journal de BIND9"
        L_A_LOGS_DHCP="Journal du serveur DHCP"
        L_A_FIREWALL="Pare-feu"
        L_A_BACKUP="Sauvegarder maintenant"
        L_A_RESTORE="Restaurer une sauvegarde"
        L_A_DERIVE="Recalculer depuis le reseau"
        L_A_RESET="Remettre les valeurs par defaut"
        L_A_REMOVE="Desinstaller BIND9 et Kea DHCP4"
        L_SVC_T="Service"
        L_SVC_ABSENT=$'L\'unite %s n\'existe pas sur cette machine.\nLe paquet est-il installe ?'
        L_SVC_OK="%s : %s effectue."
        L_SVC_KO="%s : la commande a echoue."
        L_SVC_FAIL_T="Echec du service"
        L_BOOT_OK="%s : %s au demarrage."
        L_LEASES_T="Baux DHCP"
        L_LEASES_NONE="Aucun bail enregistre pour l'instant."
        L_LEASE_ACTIVE="actif"
        L_LEASE_FREE="rendu"
        L_DIG_T="Test de resolution"
        L_DIG_ASK="Nom a resoudre :"
        L_DIG_HINT="La question est posee au serveur local (127.0.0.1)."
        L_DIG_MISSING=$'La commande dig est absente.\nInstallez bind9-dnsutils ou dnsutils.'
        L_DIAG_T="Diagnostic"
        L_DIAG_HEAD="ETAT DE LA MACHINE"
        L_DIAG_SVC="SERVICES (paquet / etat / demarrage)"
        L_DIAG_UNITS="Unites systemd"
        L_DIAG_PORTS="PORTS EN ECOUTE"
        L_DIAG_NOPORT="Aucun service n'ecoute sur 53 ou 67."
        L_DIAG_CHECK_DNS="CONTROLE DE LA CONFIGURATION DNS"
        L_DIAG_CHECK_DHCP="CONTROLE DE LA CONFIGURATION DHCP"
        L_DIAG_OK="Configuration acceptee."
        L_DIAG_RESOLV="RESOLUTION LOCALE"
        L_DIAG_LEASES="BAUX DHCP"
        L_DIAG_LEASE_N="%s bail(s) dans le fichier de baux."
        L_DIAG_LOGTAIL="DERNIERES LIGNES DU JOURNAL"
        L_CHECK_T="Verification"
        L_CHECK_RC="Code de retour : %s"
        L_CHECK_NO_BIND="named-checkconf est absent : BIND9 n'est pas installe."
        L_CHECK_NO_DHCP="kea-dhcp4 est absent : Kea n'est pas installe."
        L_CHECK_NOTHING="Aucun service actif : rien a verifier."
        L_FW_T="Pare-feu"
        L_FW_OPEN="Ouvrir les ports des services actives"
        L_FW_CLOSE="Fermer les ports DNS et DHCP"
        L_FW_STATUS="Voir l'etat du pare-feu"
        L_FW_NO_UFW=$'ufw n\'est pas installe sur cette machine.\nLes regles doivent etre posees a la main.'
        L_FW_NOPORT="Aucun service actif : aucun port a ouvrir."
        L_FW_CLOSE_Q=$'Fermer 53/tcp, 53/udp, 67/udp et 68/udp ?\n\nLes clients ne joindront plus ces services.'
        L_BACKUP_T="Sauvegarde"
        L_BACKUP_KO="La sauvegarde a echoue."
        L_RESTORE_T="Restauration"
        L_RESTORE_NONE="Aucune sauvegarde disponible."
        L_RESTORE_Q=$'Restaurer la sauvegarde %s ?\n\nLes fichiers en place seront remplaces.'
        L_RESTORE_OK=$'Sauvegarde restauree.\nRelancez les services pour la prendre en compte.'
        L_RESTORE_KO="La restauration est incomplete. Voir le journal."
        L_APPLY_T="Appliquer"
        L_WARN_OPEN_T="Resolveur ouvert"
        L_WARN_OPEN_B=$'La recursion est active et tous les clients sont autorises.\nCette machine devient un resolveur ouvert : elle peut servir\na amplifier des attaques contre des tiers.\n\nAppliquer quand meme ?'
        L_FORM_KO_T="Configuration incomplete"
        L_SUM_HEAD="Voici ce qui va etre ecrit :"
        L_SUM_DNS="DNS"
        L_SUM_DNS_OFF="DNS : desactive, service arrete"
        L_SUM_REV="Zone inverse"
        L_SUM_FWD="Redirecteurs"
        L_SUM_RECS="Enregistrements"
        L_SUM_DHCP="DHCP"
        L_SUM_DHCP_OFF="DHCP : desactive, service arrete"
        L_SUM_RANGE="Plage distribuee"
        L_SUM_RES="Reservations"
        L_SUM_BACKUP="Les fichiers en place seront sauvegardes."
        L_SUM_RESTART="Les services seront redemarres."
        L_SUM_RESOLV="/etc/resolv.conf pointera sur ce serveur."
        L_SUM_ASK="Continuer ?"
        L_REP_T="Configuration appliquee"
        L_REP_DONE="La configuration a ete ecrite et appliquee."
        L_REP_HEAD="Etat apres application :"
        L_REP_ZONEDIR="Fichiers de zone"
        L_REP_DOMAIN="Domaine"
        L_REP_RANGE="Plage DHCP"
        L_REP_CONF="Configuration"
        L_REP_LOG="Journal"
        L_REP_UNINST="Desinstallation"
        L_REP_WARN="Un service ne tourne pas : ouvrez le diagnostic (touche d)."
        L_INSTALL_T="Installation"
        L_INSTALL_OK="Les paquets demandes sont installes."
        L_INSTALL_NOTHING="Rien a installer : tout est deja en place."
        L_DHCP_MISSING_T="Kea DHCP4 indisponible"
        L_DHCP_MISSING_B=$'Le paquet kea-dhcp4-server n\'existe pas dans les\ndepots de cette distribution.\n\nLa partie DNS reste entierement utilisable. Pour le DHCP,\nactivez le depot qui fournit Kea, ou desactivez la partie DHCP.'
        L_DERIVE_T="Recalculer"
        L_DERIVE_Q=$'Relire l\'adresse, le masque et la passerelle\nde la machine et recalculer les valeurs deduites ?\n\nLes valeurs saisies a la main seront remplacees.'
        L_DERIVE_OK="Valeurs recalculees depuis le reseau de la machine."
        L_RESET_T="Valeurs par defaut"
        L_RESET_Q=$'Remettre tout le formulaire a ses valeurs par defaut ?\n\nLes fichiers deja en place ne sont pas touches.'
        L_RESET_OK="Formulaire remis a zero."
        L_REMOVE_T="Desinstallation"
        L_REMOVE_Q=$'Supprimer la configuration de BIND9 et d\'Kea DHCP4 ?\n\nLes services seront arretes et desactives.\nLes sauvegardes sont conservees.'
        L_REMOVE_PURGE_Q="Purger aussi les paquets bind9 et kea-dhcp4-server ?"
        L_REMOVE_DONE="BIND9 et Kea DHCP4 ont ete retires de cette machine."
        L_SAVE_T="Enregistrement"
        L_SAVE_OK="Configuration enregistree dans %s"
        L_SAVE_KO="Impossible d'ecrire la configuration."
        L_QUIT_T="Quitter"
        L_QUIT_ASK="Quitter le gestionnaire ?"
        L_QUIT_DIRTY=$'La configuration a ete modifiee\nsans etre enregistree.'
        L_C3_SAVE=" Enregistrer "
        L_C3_QUIT=" Quitter "
        L_C3_CANCEL=" Annuler "
        L_WELCOME_T="Bienvenue"
        L_WELCOME_B=$'Aucune configuration enregistree n\'a ete trouvee :\nles champs sont pre-remplis depuis le reseau de la machine.\n\nParcourez les sections, ajustez ce qui doit l\'etre,\npuis choisissez APPLIQUER. Rien n\'est ecrit avant.\n\nTouche a : menu des actions      Touche d : diagnostic'
        L_CONF_HEAD="Configuration de dns-dhcp-auto - ne pas editer pendant l'execution"
        L_CLI_NOCONF="Aucune configuration enregistree : lancez le script sans option."
        L_CLI_APPLIED="Configuration appliquee."
        L_KEYS=(
            "Haut/Bas|deplacer"
            "Entree|modifier / valider"
            "Espace|oui / non"
            "Gauche/Droite|plier / regler"
            "a|menu des actions"
            "d|diagnostic"
            "s|enregistrer"
            "r|actualiser l'etat"
            "t|theme clair/sombre"
            "q|quitter"
        )
    fi
}

#==============================================================================
#  3. PRIMITIVES DE DESSIN
#==============================================================================

BUF=""

put() { BUF+=$'\e['"$1;$2"'H'"$3"; }

# pad_str <texte> <largeur> -> PAD (coupe ou complete avec des espaces)
pad_str() {
    local s=$1 w=$2 n
    (( w < 0 )) && w=0
    n=${#s}
    if (( n > w )); then
        PAD=${s:0:w}
    else
        printf -v PAD '%s%*s' "$s" $(( w - n )) ''
    fi
}

# rep_char <caractere> <n> -> REPC
rep_char() {
    local n=$2
    (( n <= 0 )) && { REPC=""; return; }
    printf -v REPC '%*s' "$n" ''
    REPC=${REPC// /$1}
}

# draw_box <y> <x> <h> <w> <titre> <couleur>
draw_box() {
    local y=$1 x=$2 h=$3 w=$4 title=$5 col=$6
    local inner=$(( w - 2 )) i top
    rep_char "$BX_H" "$inner"
    local hline=$REPC
    if [[ -n $title ]]; then
        local t=" $title " tl
        tl=${#t}
        if (( tl > inner - 3 )); then
            t=" ${title:0:inner-6}.. "
            tl=${#t}
        fi
        rep_char "$BX_H" $(( inner - 1 - tl ))
        top="${BX_TL}${BX_H}${C_TITLE}${C_BOLD}${t}${C_RESET}${col}${REPC}${BX_TR}"
    else
        top="${BX_TL}${hline}${BX_TR}"
    fi
    put "$y" "$x" "${col}${top}"
    printf -v PAD '%*s' "$inner" ''
    for (( i = 1; i < h - 1; i++ )); do
        put $(( y + i )) "$x" "${col}${BX_V}${C_RESET}${PAD}${col}${BX_V}"
    done
    put $(( y + h - 1 )) "$x" "${col}${BX_BL}${hline}${BX_BR}${C_RESET}"
}

# draw_bar <y> <x> <largeur> <pourcentage>
draw_bar() {
    local y=$1 x=$2 w=$3 pct=$4
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    local barw=$(( w - 6 ))
    (( barw < 1 )) && barw=1
    local fill=$(( barw * pct / 100 ))
    rep_char "$BAR_FULL" "$fill";             local f=$REPC
    rep_char "$BAR_EMPTY" $(( barw - fill )); local e=$REPC
    printf -v PAD '%4s%%' "$pct"
    put "$y" "$x" "${C_BAR}${f}${C_BAR_BG}${e}${C_RESET}${C_BOLD}${PAD}${C_RESET}"
}

# state_color <ok|warn|err|off> -> code couleur
state_color() {
    case $1 in
        ok)   printf '%s' "$C_OK" ;;
        warn) printf '%s' "$C_WARN" ;;
        err)  printf '%s' "$C_ERR" ;;
        off)  printf '%s' "$C_MUTED" ;;
        *)    printf '%s' "$C_VALUE" ;;
    esac
}

#==============================================================================
#  4. TUX (ASCII, 4 images d'animation + 4 images d'agonie)
#==============================================================================

TUX_H=7
TUX_W=12
declare -a TUX_0 TUX_1 TUX_2 TUX_3
declare -a TUX_D0 TUX_D1 TUX_D2 TUX_D3

load_tux() {
    local l
    while IFS= read -r l; do TUX_0+=("$l"); done <<'ART0'
    .--.
   |o_o |
   |:_/ |
  //   \ \
 (|     | )
/'\_   _/`\
\___)=(___/
ART0
    while IFS= read -r l; do TUX_1+=("$l"); done <<'ART1'
    .--.
   |o_o |
   |:_/ |
  //   \ \
 (|     | )
/'\_   _/`\
(___)=(___)
ART1
    while IFS= read -r l; do TUX_2+=("$l"); done <<'ART2'
    .--.
   |-_- |
   |:_/ |
  //   \ \
 (|     | )
/'\_   _/`\
\___)=(___/
ART2
    while IFS= read -r l; do TUX_3+=("$l"); done <<'ART3'
    .--.
   |o_o |
   |:_/ |
  \\   / /
 (|     | )
/'\_   _/`\
(___)=(___)
ART3

    # Agonie, jouee quand une etape echoue : Tux encaisse le coup (yeux
    # ecarquilles, ailes en l'air), reste sonne (yeux en croix), s'affaisse
    # d'une ligne, puis finit la tete au sol et les pattes en l'air.
    while IFS= read -r l; do TUX_D0+=("$l"); done <<'DEAD0'
    .--.
   |O_O |
   |:_/ |
  \\   / /
 (|     | )
/'\_   _/`\
(___)=(___)
DEAD0
    while IFS= read -r l; do TUX_D1+=("$l"); done <<'DEAD1'
    .--.
   |x_x |
   |:_/ |
  \\   / /
 (|    | )
 /'\_ _/`\
 \__)=(__/
DEAD1
    while IFS= read -r l; do TUX_D2+=("$l"); done <<'DEAD2'

    .--.
   |x_x |
   |:_/ |
  (|    |)
 /'\_  _/`\
 \___)=(__/
DEAD2
    while IFS= read -r l; do TUX_D3+=("$l"); done <<'DEAD3'
 /___)=(___\
 \'/     \'/
  (|     |)
   \\   //
    |:_/|
    |x_x|
     '--'
DEAD3
}

# tux_line <image 0-3> <ligne 0-6> -> TUXL
tux_line() {
    case $1 in
        0) TUXL=${TUX_0[$2]} ;;
        1) TUXL=${TUX_1[$2]} ;;
        2) TUXL=${TUX_2[$2]} ;;
        *) TUXL=${TUX_3[$2]} ;;
    esac
}

# tux_death_line <image 0-3> <ligne 0-6> -> TUXL
tux_death_line() {
    case $1 in
        0) TUXL=${TUX_D0[$2]} ;;
        1) TUXL=${TUX_D1[$2]} ;;
        2) TUXL=${TUX_D2[$2]} ;;
        *) TUXL=${TUX_D3[$2]} ;;
    esac
}

#==============================================================================
#  5. OUTILS RESEAU
#==============================================================================

# valid_ip <adresse> : 0 si c'est bien une IPv4
valid_ip() {
    local ip=$1 o
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a o <<<"$ip"
    (( o[0] <= 255 && o[1] <= 255 && o[2] <= 255 && o[3] <= 255 ))
}

# valid_mask <masque> : masque contigu uniquement (255.255.255.0, pas 255.0.255.0)
valid_mask() {
    valid_ip "$1" || return 1
    local n; n=$(ip_to_int "$1")
    local inv=$(( (~n) & 0xFFFFFFFF ))
    (( ((inv + 1) & inv) == 0 ))
}

valid_mac() { [[ $1 =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; }

valid_host() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

valid_domain() {
    [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

# valid_ip_list <liste separee par des ; ou des espaces>
valid_ip_list() {
    local l=${1//;/ } i
    [[ -z ${l// /} ]] && return 1
    for i in $l; do valid_ip "$i" || return 1; done
    return 0
}

# valid_cidr_list : accepte "localhost", "any", "none", 1.2.3.4 et 1.2.3.0/24
valid_cidr_list() {
    local l=${1//;/ } i base
    [[ -z ${l// /} ]] && return 1
    for i in $l; do
        case $i in
            localhost|localnets|any|none) continue ;;
        esac
        base=${i%%/*}
        valid_ip "$base" || return 1
        if [[ $i == */* ]]; then
            local p=${i#*/}
            [[ $p =~ ^[0-9]+$ ]] && (( p <= 32 )) || return 1
        fi
    done
    return 0
}

ip_to_int() {
    local o
    IFS=. read -r -a o <<<"$1"
    printf '%s' $(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))
}

int_to_ip() {
    local n=$1
    printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
                         $(( (n >> 8) & 255 )) $(( n & 255 ))
}

mask_to_prefix() {
    local n; n=$(ip_to_int "$1")
    local p=0 i
    for (( i = 31; i >= 0; i-- )); do
        (( (n >> i) & 1 )) || break
        p=$(( p + 1 ))
    done
    printf '%s' "$p"
}

prefix_to_mask() {
    local p=$1
    (( p < 0 )) && p=0
    (( p > 32 )) && p=32
    local n=0
    (( p > 0 )) && n=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
    int_to_ip "$n"
}

# network_of <ip> <masque>
network_of() {
    valid_ip "$1" && valid_ip "$2" || { printf ''; return 1; }
    int_to_ip $(( $(ip_to_int "$1") & $(ip_to_int "$2") ))
}

# broadcast_of <ip> <masque>
broadcast_of() {
    valid_ip "$1" && valid_ip "$2" || { printf ''; return 1; }
    local n m
    n=$(ip_to_int "$1"); m=$(ip_to_int "$2")
    int_to_ip $(( (n & m) | ((~m) & 0xFFFFFFFF) ))
}

# ip_in_network <ip> <reseau> <masque>
ip_in_network() {
    valid_ip "$1" && valid_ip "$2" && valid_ip "$3" || return 1
    local m; m=$(ip_to_int "$3")
    (( ($(ip_to_int "$1") & m) == ($(ip_to_int "$2") & m) ))
}

# rev_zone_of <reseau> <masque> -> zone inverse la plus proche
# /24 et plus fin  -> 1.168.192.in-addr.arpa
# /16              -> 168.192.in-addr.arpa
# /8               -> 192.in-addr.arpa
rev_zone_of() {
    local net=$1 mask=$2 p o
    valid_ip "$net" && valid_mask "$mask" || { printf ''; return 1; }
    p=$(mask_to_prefix "$mask")
    IFS=. read -r -a o <<<"$net"
    if   (( p >= 24 )); then printf '%s.%s.%s.in-addr.arpa' "${o[2]}" "${o[1]}" "${o[0]}"
    elif (( p >= 16 )); then printf '%s.%s.in-addr.arpa' "${o[1]}" "${o[0]}"
    else                     printf '%s.in-addr.arpa' "${o[0]}"
    fi
}

# ptr_owner <ip> <zone inverse> -> nom relatif du PTR dans la zone
ptr_owner() {
    local ip=$1 zone=$2 o full
    valid_ip "$ip" || { printf ''; return 1; }
    IFS=. read -r -a o <<<"$ip"
    full="${o[3]}.${o[2]}.${o[1]}.${o[0]}.in-addr.arpa"
    if [[ -n $zone && $full == *".$zone" ]]; then
        printf '%s' "${full%".$zone"}"
    else
        printf '%s.' "$full"
    fi
}

# Liste des interfaces reseau utilisables (hors loopback).
list_ifaces() {
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 \
        | grep -vx 'lo' | sort -u
}

iface_ip() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null \
        | awk '{split($4,a,"/"); print a[1]; exit}'
}

iface_prefix() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null \
        | awk '{split($4,a,"/"); print a[2]; exit}'
}

default_iface() {
    local i
    i=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z $i ]] && i=$(list_ifaces | head -n1)
    printf '%s' "$i"
}

default_gateway() {
    ip -4 route show default 2>/dev/null | awk '{print $3; exit}'
}

#==============================================================================
#  6. ETAT DE LA MACHINE ET DES SERVICES
#==============================================================================

MI_HOST=""; MI_IP=""; MI_OS=""; MI_IFACE=""
MI_FW=""; MI_FW_ST="warn"
MI_DNS_PKG=""; MI_DNS_PKG_ST="off"
MI_DNS_SVC=""; MI_DNS_SVC_ST="off"
MI_DNS_BOOT=""; MI_DNS_BOOT_ST="off"
MI_DHCP_PKG=""; MI_DHCP_PKG_ST="off"
MI_D2_PKG=""
MI_DHCP_SVC=""; MI_DHCP_SVC_ST="off"
MI_DHCP_BOOT=""; MI_DHCP_BOOT_ST="off"
MI_P53=""; MI_P53_ST="warn"
MI_P67=""; MI_P67_ST="warn"
MI_ZONES=""; MI_LEASES=""
MI_CONF=""; MI_CONF_ST="off"

get_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z $ip ]] && ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
    [[ -z $ip ]] && ip="127.0.0.1"
    printf '%s' "$ip"
}

get_os() {
    local os=""
    [[ -r /etc/os-release ]] && os=$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME")
    [[ -z $os ]] && os=$(uname -sr)
    os=${os// GNU\/Linux/}
    os=${os%% (*}
    printf '%s' "$os"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

# pkg_known <paquet> : 0 si apt connait ce paquet
pkg_known() {
    apt-cache show "$1" >/dev/null 2>&1
}

# svc_state <unite> -> SVC_TXT / SVC_ST
svc_state() {
    local unit=$1
    if ! systemctl list-unit-files "$unit.service" >/dev/null 2>&1 || \
       [[ -z $(systemctl list-unit-files --no-legend "$unit.service" 2>/dev/null) ]]; then
        SVC_TXT="$L_V_ABSENT"; SVC_ST="off"; return
    fi
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        SVC_TXT="$L_V_RUNNING"; SVC_ST="ok"
    elif systemctl is-failed --quiet "$unit" 2>/dev/null; then
        SVC_TXT="$L_V_FAILED"; SVC_ST="err"
    else
        SVC_TXT="$L_V_STOPPED"; SVC_ST="warn"
    fi
}

# svc_boot <unite> -> BOOT_TXT / BOOT_ST
svc_boot() {
    local s
    s=$(systemctl is-enabled "$1" 2>/dev/null)
    case $s in
        enabled|enabled-runtime|alias|static|indirect)
            BOOT_TXT="$L_V_ENABLED"; BOOT_ST="ok" ;;
        disabled) BOOT_TXT="$L_V_DISABLED"; BOOT_ST="warn" ;;
        masked|masked-runtime) BOOT_TXT="$L_V_MASKED"; BOOT_ST="err" ;;
        *) BOOT_TXT="$L_V_ABSENT"; BOOT_ST="off" ;;
    esac
}

svc_enabled() {
    local s; s=$(systemctl is-enabled "$1" 2>/dev/null)
    [[ $s == enabled || $s == enabled-runtime ]]
}

detect_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qiE '^(Status|Statut)[[:space:]]*:[[:space:]]*(active|actif)'; then
            MI_FW="$L_V_ACTIVE (ufw)"; MI_FW_ST="ok"; FW_TOOL="ufw"; return
        fi
        MI_FW="$L_V_INACTIVE (ufw)"; MI_FW_ST="warn"; FW_TOOL="ufw"; return
    fi
    if command -v nft >/dev/null 2>&1 && [[ -n $(nft list ruleset 2>/dev/null) ]]; then
        MI_FW="$L_V_ACTIVE (nftables)"; MI_FW_ST="ok"; FW_TOOL="nft"; return
    fi
    if command -v iptables >/dev/null 2>&1 && (( $(iptables -S 2>/dev/null | wc -l) > 3 )); then
        MI_FW="$L_V_ACTIVE (iptables)"; MI_FW_ST="ok"; FW_TOOL="iptables"; return
    fi
    MI_FW="$L_V_NONE"; MI_FW_ST="warn"; FW_TOOL=""
}

# port_state <port> <tcp|udp> -> PORT_TXT / PORT_ST
# Un port occupe par notre propre service est une bonne nouvelle : c'est le
# rendu (couleur) qui differe, pas le texte.
port_state() {
    local port=$1 proto=$2 flag line proc=""
    [[ $proto == udp ]] && flag="-lunpH" || flag="-lntpH"
    if command -v ss >/dev/null 2>&1; then
        line=$(ss $flag 2>/dev/null | awk -v p=":$port" '{ if (index($5, p) && substr($5, length($5)-length(p)+1) == p) print }')
    else
        PORT_TXT="$L_V_UNKNOWN"; PORT_ST="warn"; return
    fi
    if [[ -z $line ]]; then
        PORT_TXT="$L_V_FREE"; PORT_ST="warn"
        return
    fi
    proc=$(printf '%s' "$line" | grep -oE '"[^"]+"' | head -n1 | tr -d '"')
    [[ -z $proc ]] && proc="?"
    PORT_TXT="$proc"
    case $proc in
        named|kea-dhcp4) PORT_ST="ok" ;;
        *)           PORT_ST="err" ;;
    esac
}

count_zones() {
    local n=0
    [[ -r $BIND_LOCAL ]] && n=$(grep -cE '^[[:space:]]*zone[[:space:]]+"' "$BIND_LOCAL" 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# Le fichier de baux de Kea est un CSV dont la premiere ligne est l'en-tete.
# Une meme adresse y figure autant de fois qu'elle a change d'etat : seule la
# derniere ligne fait foi. L'etat 0 designe un bail actif, 1 et 2 un bail rendu
# ou expire. Compter les lignes donnerait un total plusieurs fois trop grand.
count_leases() {
    local n=0
    if [[ -r $KEA_LEASES ]]; then
        n=$(awk -F, '
            NR > 1 && NF >= 10 { st[$1] = $10 }
            END { c = 0; for (a in st) if (st[a] == 0) c++; print c }
        ' "$KEA_LEASES" 2>/dev/null)
    fi
    [[ $n =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

collect_state() {
    detect_units
    MI_HOST=$(hostname -f 2>/dev/null || hostname)
    MI_IP=$(get_ip)
    MI_OS=$(get_os)
    MI_IFACE=$(default_iface)

    detect_firewall

    if pkg_installed bind9; then
        MI_DNS_PKG="$L_V_INSTALLED"; MI_DNS_PKG_ST="ok"
    else
        MI_DNS_PKG="$L_V_MISSING"; MI_DNS_PKG_ST="off"
    fi
    svc_state "$BIND_UNIT"; MI_DNS_SVC=$SVC_TXT; MI_DNS_SVC_ST=$SVC_ST
    svc_boot  "$BIND_UNIT"; MI_DNS_BOOT=$BOOT_TXT; MI_DNS_BOOT_ST=$BOOT_ST

    if pkg_installed kea-dhcp4-server; then
        MI_DHCP_PKG="$L_V_INSTALLED"; MI_DHCP_PKG_ST="ok"
    else
        MI_DHCP_PKG="$L_V_MISSING"; MI_DHCP_PKG_ST="off"
    fi
    if pkg_installed kea-dhcp-ddns-server; then
        MI_D2_PKG="$L_V_INSTALLED"
    else
        MI_D2_PKG="$L_V_MISSING"
    fi
    svc_state "$DHCP_UNIT"; MI_DHCP_SVC=$SVC_TXT; MI_DHCP_SVC_ST=$SVC_ST
    svc_boot  "$DHCP_UNIT"; MI_DHCP_BOOT=$BOOT_TXT; MI_DHCP_BOOT_ST=$BOOT_ST

    port_state 53 udp; MI_P53=$PORT_TXT; MI_P53_ST=$PORT_ST
    port_state 67 udp; MI_P67=$PORT_TXT; MI_P67_ST=$PORT_ST

    MI_ZONES=$(count_zones)
    MI_LEASES=$(count_leases)

    if [[ -r $CONF_FILE ]]; then
        MI_CONF="$L_V_SAVED"; MI_CONF_ST="ok"
    else
        MI_CONF="$L_V_NEW"; MI_CONF_ST="warn"
    fi
}

#==============================================================================
#  7. MODELE DU FORMULAIRE
#
#  Chaque champ porte une cle, un libelle, un type, une aide et, si besoin,
#  une condition d'affichage "cle=valeur". Les valeurs vivent dans VAL et sont
#  la seule source de verite : les fichiers de configuration sont toujours
#  regeneres a partir d'elles.
#
#  Types : bool (oui/non), text, num, pass, choice (liste fermee),
#          list (gere par un sous-menu dedie).
#==============================================================================

declare -a SEC_NAME SEC_OPEN
declare -a FLD_SEC FLD_KEY FLD_LABEL FLD_TYPE FLD_HINT FLD_COND FLD_OPTS
declare -A VAL

add_section() { SEC_NAME+=("$1"); SEC_OPEN+=(1); }

# add_field <cle> <libelle> <type> <valeur> <aide> [condition] [options]
add_field() {
    FLD_SEC+=($(( ${#SEC_NAME[@]} - 1 )))
    FLD_KEY+=("$1"); FLD_LABEL+=("$2"); FLD_TYPE+=("$3")
    VAL["$1"]="$4"
    FLD_HINT+=("$5"); FLD_COND+=("${6:-}"); FLD_OPTS+=("${7:-}")
}

build_form() {
    local ifl
    ifl=$(list_ifaces | tr '\n' ';'); ifl=${ifl%;}
    [[ -z $ifl ]] && ifl="eth0"

    add_section "$L_SEC_SERVICES"
    add_field dns_enable  "$L_F_DNS_ON"  bool "oui" "$L_H_DNS_ON"
    add_field dhcp_enable "$L_F_DHCP_ON" bool "oui" "$L_H_DHCP_ON"
    add_field boot_start  "$L_F_BOOT"    bool "oui" "$L_H_BOOT"

    add_section "$L_SEC_NET"
    add_field iface     "$L_F_IFACE"   choice "" "$L_H_IFACE" "" "$ifl"
    add_field server_ip "$L_F_SRVIP"   text "" "$L_H_SRVIP"
    add_field netmask   "$L_F_MASK"    text "255.255.255.0" "$L_H_MASK"
    add_field gateway   "$L_F_GW"      text "" "$L_H_GW"
    add_field domain    "$L_F_DOMAIN"  text "exemple.lan" "$L_H_DOMAIN"

    add_section "$L_SEC_DNS"
    add_field ns_name       "$L_F_NSNAME"    text "ns1" "$L_H_NSNAME" "dns_enable=oui"
    add_field dns_forward   "$L_F_ZFWD"      bool "oui" "$L_H_ZFWD" "dns_enable=oui"
    add_field dns_reverse   "$L_F_ZREV"      bool "oui" "$L_H_ZREV" "dns_enable=oui"
    add_field rev_zone      "$L_F_REVZONE"   text "" "$L_H_REVZONE" "dns_enable=oui"
    add_field admin_mail    "$L_F_ADMIN"     text "hostmaster" "$L_H_ADMIN" "dns_enable=oui"
    add_field records       "$L_F_RECORDS"   list "" "$L_H_RECORDS" "dns_enable=oui"

    add_section "$L_SEC_DNS_ADV"
    add_field dns_forwarders  "$L_F_FWDERS"   text "8.8.8.8;1.1.1.1" "$L_H_FWDERS" "dns_enable=oui"
    add_field dns_forward_only "$L_F_FWDONLY" bool "non" "$L_H_FWDONLY" "dns_enable=oui"
    add_field dns_recursion   "$L_F_RECUR"    bool "oui" "$L_H_RECUR" "dns_enable=oui"
    add_field dns_allow_query "$L_F_ALLOWQ"   text "localhost;localnets" "$L_H_ALLOWQ" "dns_enable=oui"
    add_field dns_allow_xfer  "$L_F_ALLOWX"   text "none" "$L_H_ALLOWX" "dns_enable=oui"
    add_field dns_dnssec      "$L_F_DNSSEC"   bool "oui" "$L_H_DNSSEC" "dns_enable=oui"
    add_field dns_listen6     "$L_F_LISTEN6"  bool "non" "$L_H_LISTEN6" "dns_enable=oui"
    add_field dns_hide_ver    "$L_F_HIDEVER"  bool "oui" "$L_H_HIDEVER" "dns_enable=oui"
    add_field dns_logging     "$L_F_DNSLOG"   bool "oui" "$L_H_DNSLOG" "dns_enable=oui"
    add_field ttl             "$L_F_TTL"      num  "604800" "$L_H_TTL" "dns_enable=oui"
    add_field refresh         "$L_F_REFRESH"  num  "604800" "$L_H_REFRESH" "dns_enable=oui"
    add_field retry           "$L_F_RETRY"    num  "86400" "$L_H_RETRY" "dns_enable=oui"
    add_field expire          "$L_F_EXPIRE"   num  "2419200" "$L_H_EXPIRE" "dns_enable=oui"
    add_field negttl          "$L_F_NEGTTL"   num  "604800" "$L_H_NEGTTL" "dns_enable=oui"

    add_section "$L_SEC_DHCP"
    add_field dhcp_iface   "$L_F_DIFACE"  choice "" "$L_H_DIFACE" "dhcp_enable=oui" "$ifl"
    add_field dhcp_subnet  "$L_F_SUBNET"  text "" "$L_H_SUBNET" "dhcp_enable=oui"
    add_field dhcp_mask    "$L_F_DMASK"   text "255.255.255.0" "$L_H_DMASK" "dhcp_enable=oui"
    add_field range_start  "$L_F_RSTART"  text "" "$L_H_RSTART" "dhcp_enable=oui"
    add_field range_end    "$L_F_REND"    text "" "$L_H_REND" "dhcp_enable=oui"
    add_field dhcp_routers "$L_F_ROUTERS" text "" "$L_H_ROUTERS" "dhcp_enable=oui"
    add_field dhcp_dns     "$L_F_DDNS"    text "" "$L_H_DDNS" "dhcp_enable=oui"
    add_field dhcp_domain  "$L_F_DDOMAIN" text "" "$L_H_DDOMAIN" "dhcp_enable=oui"
    add_field reservations "$L_F_RESERV"  list "" "$L_H_RESERV" "dhcp_enable=oui"

    add_section "$L_SEC_DHCP_ADV"
    add_field dhcp_lease     "$L_F_LEASE"    num  "600" "$L_H_LEASE" "dhcp_enable=oui"
    add_field dhcp_maxlease  "$L_F_MAXLEASE" num  "7200" "$L_H_MAXLEASE" "dhcp_enable=oui"
    add_field dhcp_auth      "$L_F_AUTH"     bool "oui" "$L_H_AUTH" "dhcp_enable=oui"
    add_field dhcp_deny      "$L_F_DENY"     bool "non" "$L_H_DENY" "dhcp_enable=oui"
    add_field dhcp_bcast     "$L_F_BCAST"    text "" "$L_H_BCAST" "dhcp_enable=oui"
    add_field dhcp_ntp       "$L_F_NTP"      text "" "$L_H_NTP" "dhcp_enable=oui"
    add_field dhcp_next      "$L_F_NEXTSRV"  text "" "$L_H_NEXTSRV" "dhcp_enable=oui"
    add_field dhcp_file      "$L_F_BOOTFILE" text "" "$L_H_BOOTFILE" "dhcp_enable=oui"

    add_section "$L_SEC_DDNS"
    add_field ddns_enable "$L_F_DDNS_ON"  bool "non" "$L_H_DDNS_ON"
    add_field ddns_key    "$L_F_DDNSKEY"  text "ddns-key" "$L_H_DDNSKEY" "ddns_enable=oui"
    add_field ddns_algo   "$L_F_DDNSALGO" choice "hmac-sha256" "$L_H_DDNSALGO" "ddns_enable=oui" \
              "hmac-sha256;hmac-sha512;hmac-md5"

    add_section "$L_SEC_SYS"
    add_field firewall    "$L_F_FW"       bool "oui" "$L_H_FW"
    add_field set_resolv  "$L_F_RESOLV"   bool "non" "$L_H_RESOLV"
    add_field backup      "$L_F_BACKUP"   bool "oui" "$L_H_BACKUP"
    add_field restart     "$L_F_RESTART"  bool "oui" "$L_H_RESTART"
    add_field uninstaller "$L_F_UNINST"   bool "oui" "$L_H_UNINST"
}

# Renseigne les champs deduits du reseau reel de la machine. Appelee au premier
# demarrage et par l'action "recalculer" : elle ne touche qu'aux champs vides
# sauf si <force> vaut 1.
derive_network() {
    local force=${1:-0} ifc ip pfx mask net gw
    ifc=${VAL[iface]}
    [[ -z $ifc || $force == 1 ]] && ifc=$(default_iface)
    [[ -n $ifc ]] && VAL[iface]=$ifc

    ip=$(iface_ip "$ifc")
    [[ -z $ip ]] && ip=$(get_ip)
    pfx=$(iface_prefix "$ifc")
    [[ $pfx =~ ^[0-9]+$ ]] || pfx=24
    mask=$(prefix_to_mask "$pfx")
    gw=$(default_gateway)

    set_if_empty server_ip "$ip" "$force"
    set_if_empty netmask   "$mask" "$force"
    set_if_empty gateway   "$gw" "$force"
    set_if_empty dhcp_iface "$ifc" "$force"
    set_if_empty dhcp_mask  "${VAL[netmask]}" "$force"

    net=$(network_of "${VAL[server_ip]}" "${VAL[netmask]}")
    set_if_empty dhcp_subnet "$net" "$force"
    set_if_empty dhcp_bcast  "$(broadcast_of "${VAL[server_ip]}" "${VAL[netmask]}")" "$force"
    set_if_empty rev_zone    "$(rev_zone_of "$net" "${VAL[netmask]}")" "$force"

    # plage DHCP par defaut : .100 a .200 du reseau, sans jamais englober
    # l'adresse du serveur
    if [[ -n $net ]] && valid_ip "$net"; then
        local base o
        IFS=. read -r -a o <<<"$net"
        base="${o[0]}.${o[1]}.${o[2]}"
        if [[ $(mask_to_prefix "${VAL[netmask]}") -ge 24 ]]; then
            set_if_empty range_start "$base.100" "$force"
            set_if_empty range_end   "$base.200" "$force"
        fi
    fi

    set_if_empty dhcp_routers "${VAL[gateway]}" "$force"
    set_if_empty dhcp_dns     "${VAL[server_ip]}" "$force"
    set_if_empty dhcp_domain  "${VAL[domain]}" "$force"
}

set_if_empty() {
    local k=$1 v=$2 force=$3
    [[ -z $v ]] && return
    if [[ -z ${VAL[$k]} || $force == 1 ]]; then VAL[$k]=$v; fi
}

field_index() {
    local k=$1 i
    for (( i = 0; i < ${#FLD_KEY[@]}; i++ )); do
        [[ ${FLD_KEY[i]} == "$k" ]] && { printf '%s' "$i"; return 0; }
    done
    printf '%s' "-1"
}

field_visible() {
    local c=${FLD_COND[$1]}
    [[ -z $c ]] && return 0
    local k=${c%%=*} v=${c#*=}
    [[ ${VAL[$k]} == "$v" ]]
}

declare -a VR_TYPE VR_IDX

build_rows() {
    VR_TYPE=(); VR_IDX=()
    local s i
    for (( s = 0; s < ${#SEC_NAME[@]}; s++ )); do
        # une section entierement masquee disparait aussi de la liste
        local vis=0
        for (( i = 0; i < ${#FLD_KEY[@]}; i++ )); do
            (( FLD_SEC[i] == s )) || continue
            field_visible "$i" && { vis=1; break; }
        done
        (( vis )) || continue
        VR_TYPE+=("sec"); VR_IDX+=("$s")
        if (( SEC_OPEN[s] )); then
            for (( i = 0; i < ${#FLD_KEY[@]}; i++ )); do
                (( FLD_SEC[i] == s )) || continue
                field_visible "$i" || continue
                VR_TYPE+=("fld"); VR_IDX+=("$i")
            done
        fi
        VR_TYPE+=("gap"); VR_IDX+=("-1")
    done
    # pas de ligne vide en toute fin de liste
    local n=${#VR_TYPE[@]}
    if (( n > 0 )) && [[ ${VR_TYPE[n-1]} == gap ]]; then
        unset 'VR_TYPE[n-1]' 'VR_IDX[n-1]'
    fi
}

# nombre d'elements d'une liste "a|b|c;d|e|f"
list_count() {
    local l=$1
    [[ -z $l ]] && { printf '0'; return; }
    local IFS=';' ; local -a a=($l)
    printf '%s' "${#a[@]}"
}

# valeur affichee d'un champ -> DISPV / DISPC
field_display() {
    local i=$1 key=${FLD_KEY[$1]} type=${FLD_TYPE[$1]} v=${VAL[${FLD_KEY[$1]}]}
    case $type in
        bool)
            if [[ $v == oui ]]; then DISPV="< $L_YESV >"; DISPC=$C_OK
            else DISPV="< $L_NOV >"; DISPC=$C_MUTED; fi
            ;;
        choice)
            if [[ -z $v ]]; then DISPV="($L_EMPTY)"; DISPC=$C_WARN
            else DISPV="< $v >"; DISPC=$C_VALUE; fi
            ;;
        list)
            local n; n=$(list_count "$v")
            DISPV=$(printf "$L_LIST_COUNT" "$n")
            if (( n > 0 )); then DISPC=$C_VALUE; else DISPC=$C_MUTED; fi
            ;;
        pass)
            if [[ -z $v ]]; then DISPV="($L_UNSET)"; DISPC=$C_WARN
            else
                local n=${#v}; (( n > 16 )) && n=16
                rep_char '*' "$n"; DISPV=$REPC; DISPC=$C_VALUE
            fi
            ;;
        *)
            if [[ -z $v ]]; then DISPV="($L_EMPTY)"; DISPC=$C_WARN
            else DISPV=$v; DISPC=$C_VALUE; fi
            ;;
    esac
}

#==============================================================================
#  8. PERSISTANCE DE LA CONFIGURATION
#
#  Format volontairement trivial : une ligne "cle=valeur" par champ, aucune
#  substitution au chargement. Le fichier n'est jamais execute.
#==============================================================================

save_config() {
    local i k
    mkdir -p "$CONF_DIR" 2>/dev/null || return 1
    {
        printf '# %s\n' "$L_CONF_HEAD"
        printf '# %s\n' "$(date '+%F %T')"
        printf 'version=%s\n' "$SCRIPT_VERSION"
        printf 'lang=%s\n' "$UILANG"
        for (( i = 0; i < ${#FLD_KEY[@]}; i++ )); do
            k=${FLD_KEY[i]}
            printf '%s=%s\n' "$k" "${VAL[$k]}"
        done
    } >"$CONF_FILE.tmp" 2>/dev/null || return 1
    chmod 600 "$CONF_FILE.tmp" 2>/dev/null
    mv -f "$CONF_FILE.tmp" "$CONF_FILE" 2>/dev/null || return 1
    return 0
}

load_config() {
    [[ -r $CONF_FILE ]] || return 1
    local line k v known=0 i
    while IFS= read -r line; do
        [[ $line == \#* || -z $line ]] && continue
        [[ $line == *=* ]] || continue
        k=${line%%=*}
        v=${line#*=}
        [[ $k == lang && -n $v ]] && { CONF_LANG=$v; continue; }
        known=0
        for (( i = 0; i < ${#FLD_KEY[@]}; i++ )); do
            [[ ${FLD_KEY[i]} == "$k" ]] && { known=1; break; }
        done
        (( known )) && VAL[$k]=$v
    done <"$CONF_FILE"
    return 0
}

# Lit uniquement la langue enregistree, avant meme la construction du
# formulaire, pour ne pas reposer la question a chaque lancement.
peek_conf_lang() {
    CONF_LANG=""
    [[ -r $CONF_FILE ]] || return 1
    CONF_LANG=$(grep -m1 '^lang=' "$CONF_FILE" 2>/dev/null | cut -d= -f2)
    [[ -n $CONF_LANG ]]
}

#==============================================================================
#  9. RENDU DE L'ECRAN PRINCIPAL
#==============================================================================

SEL=0          # index de ligne ; == nb de lignes -> barre de boutons
BTN_CUR=0      # bouton actif dans la barre du bas
SCROLL=0
STATUS_MSG=""
STATUS_KIND="info"

declare -a BTN_KEY BTN_LABEL

build_buttons() {
    BTN_KEY=(apply actions diag quit)
    BTN_LABEL=("$L_BTN_APPLY" "$L_BTN_ACTIONS" "$L_BTN_DIAG" "$L_BTN_QUIT")
}

sel_is_button() { (( SEL >= ${#VR_TYPE[@]} )); }
btn_index() { printf '%s' "$BTN_CUR"; }

adjust_scroll() {
    local n=${#VR_TYPE[@]}
    sel_is_button && return
    (( SEL < SCROLL )) && SCROLL=$SEL
    (( SEL >= SCROLL + FORM_ROWS )) && SCROLL=$(( SEL - FORM_ROWS + 1 ))
    (( SCROLL > n - FORM_ROWS )) && SCROLL=$(( n - FORM_ROWS ))
    (( SCROLL < 0 )) && SCROLL=0
}

render_header() {
    local title="$L_APP_TITLE"
    draw_box "$HEAD_Y" 1 "$HEAD_H" "$COLS" "" "$C_FRAME"
    local x=$(( (COLS - ${#title}) / 2 ))
    (( x < 2 )) && x=2
    put $(( HEAD_Y + 1 )) "$x" "${C_BOLD}${C_TITLE}${title}${C_RESET}"
    put $(( HEAD_Y + 1 )) $(( COLS - 10 )) "${C_MUTED}v${SCRIPT_VERSION}${C_RESET}"
    if (( DIRTY )); then
        put $(( HEAD_Y + 1 )) 3 "${C_WARN}${C_BOLD}${L_MODIFIED}${C_RESET}"
    fi
}

render_form() {
    local col=$C_FRAME
    sel_is_button || col=$C_FRAME_ON
    draw_box "$BODY_Y" "$FORM_X" "$BODY_H" "$FORM_W" "$L_PANEL_CONFIG" "$col"

    local inner=$(( FORM_W - 4 ))
    local labw=$(( inner - 24 ))
    (( labw > 34 )) && labw=34
    (( labw < 16 )) && labw=16
    local n=${#VR_TYPE[@]} r y i idx

    for (( r = 0; r < FORM_ROWS; r++ )); do
        i=$(( SCROLL + r ))
        (( i >= n )) && break
        y=$(( BODY_Y + 1 + r ))
        idx=${VR_IDX[i]}
        case ${VR_TYPE[i]} in
            sec)
                local mark="v"
                (( SEC_OPEN[idx] )) || mark=">"
                pad_str " ${mark} ${SEC_NAME[idx]}" "$inner"
                if (( SEL == i )); then
                    put "$y" $(( FORM_X + 1 )) "${C_SEL}${C_BOLD}${C_SEC} ${PAD} ${C_RESET}"
                else
                    put "$y" $(( FORM_X + 1 )) "${C_BOLD}${C_SEC} ${PAD} ${C_RESET}"
                fi
                ;;
            fld)
                field_display "$idx"
                pad_str "    ${FLD_LABEL[idx]}" $(( labw - 1 ))
                local lab="$PAD "
                pad_str "$DISPV" $(( inner - labw ))
                local val=$PAD
                if (( SEL == i )); then
                    put "$y" $(( FORM_X + 1 )) "${C_SEL} ${C_BOLD}${C_LABEL}${lab}${DISPC}${val}${C_RESET}${C_SEL} ${C_RESET}"
                else
                    put "$y" $(( FORM_X + 1 )) " ${C_LABEL}${lab}${DISPC}${val}${C_RESET} "
                fi
                ;;
            *)
                ;;
        esac
    done

    (( SCROLL > 0 )) && put "$BODY_Y" $(( FORM_X + FORM_W - 5 )) "${C_FRAME}[^]${C_RESET}"
    (( SCROLL + FORM_ROWS < n )) && put $(( BODY_Y + BODY_H - 1 )) $(( FORM_X + FORM_W - 5 )) "${C_FRAME}[v]${C_RESET}"
}

render_state() {
    draw_box "$BODY_Y" "$RIGHT_X" "$MACH_H" "$RIGHT_W" "$L_PANEL_STATE" "$C_FRAME"
    local inner=$(( RIGHT_W - 4 ))
    local labw=13
    local y=$(( BODY_Y + 1 ))
    local -a rows
    local zl; zl=$(printf '%s / %s' "$MI_ZONES" "$MI_LEASES")
    if (( MACH_H >= 13 )); then
        rows=(
            "$L_M_HOST|$MI_HOST|"
            "$L_M_IP|$MI_IP ($MI_IFACE)|"
            "$L_M_OS|$MI_OS|"
            "$L_M_FW|$MI_FW|$MI_FW_ST"
            "$L_M_DNS_SVC|$MI_DNS_SVC|$MI_DNS_SVC_ST"
            "$L_M_DNS_BOOT|$MI_DNS_BOOT|$MI_DNS_BOOT_ST"
            "$L_M_DHCP_SVC|$MI_DHCP_SVC|$MI_DHCP_SVC_ST"
            "$L_M_DHCP_BOOT|$MI_DHCP_BOOT|$MI_DHCP_BOOT_ST"
            "$L_M_P53|$MI_P53|$MI_P53_ST"
            "$L_M_P67|$MI_P67|$MI_P67_ST"
            "$L_M_ZONES|$zl|"
        )
    else
        local dns_st=$MI_DNS_SVC_ST dhcp_st=$MI_DHCP_SVC_ST
        rows=(
            "$L_M_HOST|$MI_HOST|"
            "$L_M_IP|$MI_IP ($MI_IFACE)|"
            "$L_M_DNS_SVC|$MI_DNS_SVC|$dns_st"
            "$L_M_DHCP_SVC|$MI_DHCP_SVC|$dhcp_st"
            "$L_M_PORTS|$MI_P53 / $MI_P67|"
            "$L_M_FW|$MI_FW|$MI_FW_ST"
            "$L_M_ZONES|$zl|"
        )
    fi
    local r lab val st c
    for r in "${rows[@]}"; do
        IFS='|' read -r lab val st <<<"$r"
        c=$C_VALUE
        [[ -n $st ]] && c=$(state_color "$st")
        pad_str "$lab" "$labw"; local L=$PAD
        pad_str "$val" $(( inner - labw - 2 )); local V=$PAD
        put "$y" $(( RIGHT_X + 2 )) "${C_MUTED}${L}${C_RESET}: ${c}${V}${C_RESET}"
        y=$(( y + 1 ))
    done
}

render_help() {
    local y=$(( BODY_Y + MACH_H ))
    draw_box "$y" "$RIGHT_X" "$HELP_H" "$RIGHT_W" "$L_PANEL_KEYS" "$C_FRAME"
    local inner=$(( RIGHT_W - 4 ))
    local i=0 k lab
    for k in "${L_KEYS[@]}"; do
        (( i >= HELP_H - 2 )) && break
        IFS='|' read -r lab k <<<"$k"
        pad_str "$lab" 15; local L=$PAD
        pad_str "$k" $(( inner - 15 )); local V=$PAD
        put $(( y + 1 + i )) $(( RIGHT_X + 2 )) "${C_BOLD}${C_LABEL}${L}${C_RESET}${C_MUTED}${V}${C_RESET}"
        i=$(( i + 1 ))
    done

    if (( HELP_H >= 13 )); then
        local notes=(
            "$L_NOTE_CONF"
            "  $CONF_FILE"
            "$L_NOTE_LOG"
            "  $LOGFILE"
        )
        rep_char "$BX_H" "$inner"
        put $(( y + HELP_H - 6 )) $(( RIGHT_X + 2 )) "${C_FRAME}${REPC}${C_RESET}"
        local j=0
        for k in "${notes[@]}"; do
            pad_str "$k" "$inner"
            put $(( y + HELP_H - 5 + j )) $(( RIGHT_X + 2 )) "${C_MUTED}${PAD}${C_RESET}"
            j=$(( j + 1 ))
        done
    fi
}

render_buttons() {
    local col=$C_FRAME
    sel_is_button && col=$C_FRAME_ON
    draw_box "$FOOT_Y" 1 "$FOOT_H" "$COLS" "" "$col"

    local nb=${#BTN_LABEL[@]} total=0 i
    for (( i = 0; i < nb; i++ )); do total=$(( total + ${#BTN_LABEL[i]} + 2 )); done
    local x=$(( (COLS - total) / 2 ))
    (( x < 2 )) && x=2
    local cur=$(btn_index)
    for (( i = 0; i < nb; i++ )); do
        if sel_is_button && (( cur == i )); then
            put $(( FOOT_Y + 1 )) "$x" "${C_BTN_ON}${C_BOLD}${BTN_LABEL[i]}${C_RESET}"
        else
            put $(( FOOT_Y + 1 )) "$x" "${C_BTN}${BTN_LABEL[i]}${C_RESET}"
        fi
        x=$(( x + ${#BTN_LABEL[i]} + 2 ))
    done
}

render_status() {
    local txt=$STATUS_MSG c=$C_MUTED
    case $STATUS_KIND in
        err)  c=$C_ERR ;;
        ok)   c=$C_OK ;;
        warn) c=$C_WARN ;;
    esac
    if [[ -z $txt ]]; then
        if sel_is_button; then
            local b=${BTN_KEY[$(btn_index)]:-}
            case $b in
                apply)   txt="$L_ST_APPLY" ;;
                actions) txt="$L_ST_ACTIONS" ;;
                diag)    txt="$L_ST_DIAG" ;;
                quit)    txt="$L_ST_QUIT" ;;
            esac
        else
            local i=${VR_IDX[$SEL]}
            if [[ ${VR_TYPE[$SEL]} == fld ]]; then
                txt=${FLD_HINT[i]}
            elif [[ ${VR_TYPE[$SEL]} == sec ]]; then
                txt="$L_ST_SECTION"
            fi
        fi
    fi
    pad_str " $txt" "$COLS"
    put "$ROWS" 1 "${c}${PAD}${C_RESET}"
}

render_main() {
    BUF=$'\e[2J'
    if term_too_small; then
        put 1 1 "${C_ERR}$(printf "$L_TOO_SMALL" "$COLS" "$ROWS")${C_RESET}"
        printf '%s' "$BUF"
        return
    fi
    render_header
    render_form
    render_state
    render_help
    render_buttons
    render_status
    printf '%s' "$BUF"
}

#==============================================================================
#  10. SAISIE CLAVIER
#==============================================================================

KEY=""

read_key() {
    local k rest
    KEY=""
    IFS= read -rsn1 k 2>/dev/null || { KEY="NONE"; return 0; }
    case "$k" in
        "")     KEY="ENTER" ;;
        $'\e')
            IFS= read -rsn2 -t 0.05 rest 2>/dev/null
            case "$rest" in
                "[A") KEY="UP" ;;
                "[B") KEY="DOWN" ;;
                "[C") KEY="RIGHT" ;;
                "[D") KEY="LEFT" ;;
                "[H") KEY="HOME" ;;
                "[F") KEY="END" ;;
                "[5") IFS= read -rsn1 -t 0.05 2>/dev/null; KEY="PGUP" ;;
                "[6") IFS= read -rsn1 -t 0.05 2>/dev/null; KEY="PGDN" ;;
                "")   KEY="ESC" ;;
                *)    KEY="OTHER" ;;
            esac
            ;;
        " ")     KEY="SPACE" ;;
        $'\t')   KEY="TAB" ;;
        $'\x7f') KEY="BACK" ;;
        *)       KEY="CHAR:$k" ;;
    esac
}

wait_key() { local k; IFS= read -rsn1 k 2>/dev/null; }

#==============================================================================
#  11. FENETRES MODALES
#==============================================================================

# modal_box <h> <w> <titre> -> MX / MY (coin haut gauche)
modal_box() {
    local h=$1 w=$2 title=$3
    MY=$(( (ROWS - h) / 2 )); MX=$(( (COLS - w) / 2 ))
    (( MY < 1 )) && MY=1
    (( MX < 1 )) && MX=1
    BUF=""
    draw_box "$MY" "$MX" "$h" "$w" "$title" "$C_FRAME_ON"
    printf '%s' "$BUF"
}

# edit_line <y> <x> <largeur> <valeur> <masque 0/1> -> EDITED (0 = valide)
edit_line() {
    local y=$1 x=$2 w=$3 buf=$4 mask=$5 k rest disp
    cursor_show
    while :; do
        if (( mask )); then
            rep_char '*' "${#buf}"; disp=$REPC
        else
            disp=$buf
        fi
        (( ${#disp} > w )) && disp=${disp: -w}
        pad_str "$disp" "$w"
        printf '\e[%d;%dH%s%s%s' "$y" "$x" "$C_VALUE" "$PAD" "$C_RESET"
        printf '\e[%d;%dH' "$y" $(( x + ${#disp} ))
        IFS= read -rsn1 k 2>/dev/null || continue
        case "$k" in
            "") EDITED=$buf; cursor_hide; return 0 ;;
            $'\e')
                IFS= read -rsn2 -t 0.05 rest 2>/dev/null
                [[ -z $rest ]] && { cursor_hide; return 1; }
                ;;
            $'\x7f'|$'\b') buf=${buf%?} ;;
            $'\x15') buf="" ;;
            *)
                if [[ $k == [[:print:]] || $(printf '%d' "'$k" 2>/dev/null) -gt 127 ]]; then
                    (( ${#buf} < 200 )) && buf+="$k"
                fi
                ;;
        esac
    done
}

# modal_message <titre> <texte multi-lignes> [couleur]
modal_message() {
    local title=$1 text=$2 col=${3:-$C_VALUE}
    if (( CLI_MODE )); then
        printf '\n%s\n%s\n' "$title" "$text"
        return 0
    fi
    local -a lines
    local w=0 l
    while IFS= read -r l; do lines+=("$l"); (( ${#l} > w )) && w=${#l}; done <<<"$text"
    w=$(( w + 6 ))
    (( w > COLS - 4 )) && w=$(( COLS - 4 ))
    (( w < 44 )) && w=44
    local h=$(( ${#lines[@]} + 4 ))
    (( h > ROWS - 2 )) && h=$(( ROWS - 2 ))
    modal_box "$h" "$w" "$title"
    BUF=""
    local i
    for (( i = 0; i < ${#lines[@]} && i < h - 4; i++ )); do
        pad_str "${lines[i]}" $(( w - 4 ))
        put $(( MY + 1 + i )) $(( MX + 2 )) "${col}${PAD}${C_RESET}"
    done
    pad_str "$L_ANY_KEY" $(( w - 4 ))
    put $(( MY + h - 2 )) $(( MX + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    printf '%s' "$BUF"
    wait_key
}

# modal_confirm <titre> <question> [defaut 0=oui 1=non] -> 0 = oui
modal_confirm() {
    local title=$1 text=$2 choice=${3:-0}
    # En ligne de commande, l'utilisateur a deja donne son accord en passant
    # l'option : on ne repose pas la question.
    (( CLI_MODE )) && return 0
    local -a lines
    local w=0 l
    while IFS= read -r l; do lines+=("$l"); (( ${#l} > w )) && w=${#l}; done <<<"$text"
    w=$(( w + 6 )); (( w < 48 )) && w=48
    (( w > COLS - 4 )) && w=$(( COLS - 4 ))
    local h=$(( ${#lines[@]} + 5 ))
    (( h > ROWS - 2 )) && h=$(( ROWS - 2 ))
    local maxl=$(( h - 5 ))
    modal_box "$h" "$w" "$title"
    while :; do
        BUF=""
        local i
        for (( i = 0; i < ${#lines[@]} && i < maxl; i++ )); do
            pad_str "${lines[i]}" $(( w - 4 ))
            put $(( MY + 1 + i )) $(( MX + 2 )) "${C_VALUE}${PAD}${C_RESET}"
        done
        local yes="$L_YES" no="$L_NO"
        local by=$(( MY + h - 2 )) bx=$(( MX + w - 20 ))
        if (( choice == 0 )); then
            put "$by" "$bx" "${C_BTN_ON}${C_BOLD}${yes}${C_RESET}  ${C_MUTED}${no}${C_RESET}"
        else
            put "$by" "$bx" "${C_MUTED}${yes}${C_RESET}  ${C_BTN_ON}${C_BOLD}${no}${C_RESET}"
        fi
        printf '%s' "$BUF"
        read_key
        case $KEY in
            LEFT|RIGHT|TAB) choice=$(( 1 - choice )) ;;
            ENTER) return $choice ;;
            ESC) return 1 ;;
            "CHAR:o"|"CHAR:O"|"CHAR:y"|"CHAR:Y") return 0 ;;
            "CHAR:n"|"CHAR:N") return 1 ;;
        esac
    done
}

# modal_edit <titre> <invite> <valeur> <masque> <aide> -> EDITED
modal_edit() {
    local title=$1 prompt=$2 cur=$3 mask=$4 hint=$5
    local w=68
    (( w > COLS - 4 )) && w=$(( COLS - 4 ))
    local h=9
    modal_box "$h" "$w" "$title"
    BUF=""
    pad_str "$prompt" $(( w - 4 ))
    put $(( MY + 1 )) $(( MX + 2 )) "${C_LABEL}${PAD}${C_RESET}"
    pad_str "$hint" $(( w - 4 ))
    put $(( MY + 2 )) $(( MX + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    rep_char "$BX_H" $(( w - 6 ))
    put $(( MY + 5 )) $(( MX + 3 )) "${C_FRAME}${REPC}${C_RESET}"
    pad_str "$L_EDIT_HELP" $(( w - 4 ))
    put $(( MY + 6 )) $(( MX + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    printf '%s' "$BUF"
    edit_line $(( MY + 4 )) $(( MX + 3 )) $(( w - 6 )) "$cur" "$mask"
}

#------------------------------------------------------------------ menu liste
# Rempli LM_LABEL (libelles) et facultativement LM_STATE (ok/warn/err/off)
# avant l'appel. Renvoie 0 avec LM_SEL positionne, 1 si l'utilisateur sort.
declare -a LM_LABEL LM_STATE
LM_SEL=0

list_menu() {
    local title=$1 help=${2:-$L_MENU_HELP}
    local n=${#LM_LABEL[@]}
    (( n == 0 )) && { modal_message "$title" "$L_MENU_EMPTY" "$C_WARN"; return 1; }
    local sel=$LM_SEL top=0
    (( sel >= n )) && sel=$(( n - 1 ))
    (( sel < 0 )) && sel=0

    while :; do
        (( RESIZED )) && { compute_layout; RESIZED=0; }
        local w=0 l
        for l in "${LM_LABEL[@]}"; do (( ${#l} > w )) && w=${#l}; done
        w=$(( w + 8 ))
        (( ${#help} + 6 > w )) && w=$(( ${#help} + 6 ))
        (( w > COLS - 4 )) && w=$(( COLS - 4 ))
        (( w < 46 )) && w=46
        local rv=$(( ROWS - 8 ))
        (( rv > n )) && rv=$n
        (( rv < 1 )) && rv=1
        local h=$(( rv + 5 ))
        local y=$(( (ROWS - h) / 2 )) x=$(( (COLS - w) / 2 ))
        (( y < 1 )) && y=1
        (( x < 1 )) && x=1
        (( sel < top )) && top=$sel
        (( sel >= top + rv )) && top=$(( sel - rv + 1 ))
        (( top > n - rv )) && top=$(( n - rv ))
        (( top < 0 )) && top=0

        BUF=$'\e[2J'
        draw_box "$y" "$x" "$h" "$w" "$title" "$C_FRAME_ON"
        local inner=$(( w - 4 )) r idx c
        for (( r = 0; r < rv; r++ )); do
            idx=$(( top + r ))
            (( idx >= n )) && break
            c=$C_VALUE
            [[ -n ${LM_STATE[idx]:-} ]] && c=$(state_color "${LM_STATE[idx]}")
            pad_str "  ${LM_LABEL[idx]}" "$inner"
            if (( sel == idx )); then
                put $(( y + 1 + r )) $(( x + 2 )) "${C_SEL}${C_BOLD}${c}${PAD}${C_RESET}"
            else
                put $(( y + 1 + r )) $(( x + 2 )) "${c}${PAD}${C_RESET}"
            fi
        done
        rep_char "$BX_H" "$inner"
        put $(( y + h - 3 )) $(( x + 2 )) "${C_FRAME}${REPC}${C_RESET}"
        pad_str "$help" "$inner"
        put $(( y + h - 2 )) $(( x + 2 )) "${C_MUTED}${PAD}${C_RESET}"
        # les fleches de defilement sont posees en dernier : elles se placent
        # sur le cadre et sur le trait de separation, jamais l'inverse
        (( top > 0 )) && put "$y" $(( x + w - 5 )) "${C_FRAME}[^]${C_RESET}"
        (( top + rv < n )) && put $(( y + h - 3 )) $(( x + w - 5 )) "${C_FRAME}[v]${C_RESET}"
        printf '%s' "$BUF"

        read_key
        case $KEY in
            UP|"CHAR:k")   (( sel > 0 )) && sel=$(( sel - 1 )) ;;
            DOWN|"CHAR:j") (( sel < n - 1 )) && sel=$(( sel + 1 )) ;;
            PGUP) sel=$(( sel - rv )); (( sel < 0 )) && sel=0 ;;
            PGDN) sel=$(( sel + rv )); (( sel > n - 1 )) && sel=$(( n - 1 )) ;;
            HOME) sel=0 ;;
            END)  sel=$(( n - 1 )) ;;
            ENTER|SPACE) LM_SEL=$sel; return 0 ;;
            ESC|"CHAR:q"|"CHAR:Q") LM_SEL=$sel; return 1 ;;
            "CHAR:a"|"CHAR:A") LM_SEL=-1; LM_ACT="add"; return 0 ;;
            "CHAR:s"|"CHAR:S") LM_SEL=$sel; LM_ACT="del"; return 0 ;;
        esac
    done
}

#--------------------------------------------------------- afficheur de texte
# text_view <titre> <texte> : lecture seule, defilement clavier.
text_view() {
    local title=$1 text=$2
    if (( CLI_MODE )); then
        printf '\n%s\n%s\n' "$title" "$text"
        return 0
    fi
    local -a lines
    local l
    while IFS= read -r l; do lines+=("$l"); done <<<"$text"
    (( ${#lines[@]} == 0 )) && lines=("$L_VIEW_EMPTY")
    local n=${#lines[@]} top=0

    while :; do
        (( RESIZED )) && { compute_layout; RESIZED=0; }
        local w=$(( COLS - 6 ))
        (( w < 40 )) && w=40
        local h=$(( ROWS - 4 ))
        (( h < 8 )) && h=8
        local rv=$(( h - 4 ))
        (( top > n - rv )) && top=$(( n - rv ))
        (( top < 0 )) && top=0
        local y=$(( (ROWS - h) / 2 )) x=$(( (COLS - w) / 2 ))
        (( y < 1 )) && y=1
        (( x < 1 )) && x=1

        BUF=$'\e[2J'
        draw_box "$y" "$x" "$h" "$w" "$title" "$C_FRAME_ON"
        local inner=$(( w - 4 )) r idx
        for (( r = 0; r < rv; r++ )); do
            idx=$(( top + r ))
            (( idx >= n )) && break
            pad_str "${lines[idx]}" "$inner"
            put $(( y + 1 + r )) $(( x + 2 )) "${C_VALUE}${PAD}${C_RESET}"
        done
        rep_char "$BX_H" "$inner"
        put $(( y + h - 3 )) $(( x + 2 )) "${C_FRAME}${REPC}${C_RESET}"
        pad_str "$(printf "$L_VIEW_HELP" $(( top + 1 )) "$n")" "$inner"
        put $(( y + h - 2 )) $(( x + 2 )) "${C_MUTED}${PAD}${C_RESET}"
        printf '%s' "$BUF"

        read_key
        case $KEY in
            UP|"CHAR:k")   top=$(( top - 1 )) ;;
            DOWN|"CHAR:j") top=$(( top + 1 )) ;;
            PGUP) top=$(( top - rv )) ;;
            PGDN|SPACE) top=$(( top + rv )) ;;
            HOME) top=0 ;;
            END)  top=$(( n - rv )) ;;
            ESC|ENTER|"CHAR:q"|"CHAR:Q") return 0 ;;
        esac
    done
}

# --- Choix de la langue au demarrage ---------------------------------------
select_language() {
    local sel=0 i
    local -a codes=("fr" "en")
    local -a names=("Francais" "English")

    case "${DDAUTO_LANG:-}" in
        fr|FR|fr_FR) UILANG="fr"; return 0 ;;
        en|EN|en_US) UILANG="en"; return 0 ;;
    esac
    if peek_conf_lang; then
        case $CONF_LANG in
            fr) UILANG="fr"; return 0 ;;
            en) UILANG="en"; return 0 ;;
        esac
    fi

    while :; do
        (( RESIZED )) && { compute_layout; RESIZED=0; }
        local w=48 h=10
        (( w > COLS - 4 )) && w=$(( COLS - 4 ))
        local y=$(( (ROWS - h) / 2 )) x=$(( (COLS - w) / 2 ))
        (( y < 1 )) && y=1
        (( x < 1 )) && x=1

        BUF=$'\e[2J'
        draw_box "$y" "$x" "$h" "$w" "DNS-DHCP AUTO" "$C_FRAME_ON"
        pad_str "Choisissez votre langue" $(( w - 4 ))
        put $(( y + 1 )) $(( x + 2 )) "${C_LABEL}${PAD}${C_RESET}"
        pad_str "Choose your language" $(( w - 4 ))
        put $(( y + 2 )) $(( x + 2 )) "${C_MUTED}${PAD}${C_RESET}"
        for (( i = 0; i < ${#names[@]}; i++ )); do
            pad_str "${names[i]}" $(( w - 8 ))
            if (( sel == i )); then
                put $(( y + 4 + i )) $(( x + 2 )) "${C_SEL}${C_BOLD}${C_VALUE}  > ${PAD} ${C_RESET}"
            else
                put $(( y + 4 + i )) $(( x + 2 )) "${C_VALUE}    ${PAD} ${C_RESET}"
            fi
        done
        pad_str "Fleches + Entree / Arrows + Enter" $(( w - 4 ))
        put $(( y + h - 2 )) $(( x + 2 )) "${C_MUTED}${PAD}${C_RESET}"
        printf '%s' "$BUF"

        read_key
        case $KEY in
            UP|"CHAR:k")   (( sel > 0 )) && sel=$(( sel - 1 )) ;;
            DOWN|"CHAR:j"|TAB) (( sel < ${#names[@]} - 1 )) && sel=$(( sel + 1 )) ;;
            "CHAR:f"|"CHAR:F") sel=0 ;;
            "CHAR:e"|"CHAR:E") sel=1 ;;
            ENTER|SPACE) UILANG=${codes[sel]}; return 0 ;;
            ESC|"CHAR:q"|"CHAR:Q") return 1 ;;
        esac
    done
}

#==============================================================================
#  12. INTERACTION AVEC LE FORMULAIRE
#==============================================================================

toggle_bool() {
    local key=$1
    if [[ ${VAL[$key]} == oui ]]; then VAL[$key]="non"; else VAL[$key]="oui"; fi
    DIRTY=1
}

# cycle_choice <index de champ> <sens 1|-1>
cycle_choice() {
    local i=$1 dir=$2 key=${FLD_KEY[$1]}
    local IFS=';'
    local -a opts=(${FLD_OPTS[$i]})
    IFS=$' \t\n'
    local n=${#opts[@]}
    (( n == 0 )) && return
    local cur=0 j
    for (( j = 0; j < n; j++ )); do
        [[ ${opts[j]} == "${VAL[$key]}" ]] && { cur=$j; break; }
    done
    cur=$(( (cur + dir + n) % n ))
    VAL[$key]=${opts[cur]}
    DIRTY=1
}

validate_value() {
    # validate_value <type de controle> <valeur> -> 0 ok, sinon VERR
    local kind=$1 v=$2
    VERR=""
    case $kind in
        ip)     valid_ip "$v" || VERR="$L_ERR_IP" ;;
        ip_opt) [[ -z $v ]] || valid_ip "$v" || VERR="$L_ERR_IP" ;;
        mask)   valid_mask "$v" || VERR="$L_ERR_MASK" ;;
        host)   valid_host "$v" || VERR="$L_ERR_HOST" ;;
        domain) valid_domain "$v" || VERR="$L_ERR_DOMAIN" ;;
        zone)   [[ $v =~ ^[a-zA-Z0-9._-]+$ ]] || VERR="$L_ERR_ZONE" ;;
        mail)   [[ $v =~ ^[a-zA-Z0-9._-]+$ ]] || VERR="$L_ERR_MAIL" ;;
        iplist) [[ -z $v ]] || valid_ip_list "$v" || VERR="$L_ERR_IPLIST" ;;
        acl)    valid_cidr_list "$v" || VERR="$L_ERR_ACL" ;;
        mac)    valid_mac "$v" || VERR="$L_ERR_MAC" ;;
        num)
            if [[ ! $v =~ ^[0-9]+$ ]]; then VERR="$L_ERR_NUM"
            elif (( v < 1 || v > 2147483647 )); then VERR="$L_ERR_NUM_RANGE"
            fi
            ;;
        path)   [[ -z $v ]] || [[ $v =~ ^[a-zA-Z0-9._/-]+$ ]] || VERR="$L_ERR_PATH" ;;
    esac
    [[ -z $VERR ]]
}

field_check_kind() {
    case ${FLD_KEY[$1]} in
        server_ip)                        printf 'ip' ;;
        netmask|dhcp_mask)                printf 'mask' ;;
        gateway|dhcp_bcast|dhcp_next)     printf 'ip_opt' ;;
        dhcp_subnet|range_start|range_end) printf 'ip' ;;
        domain|dhcp_domain)               printf 'domain' ;;
        ns_name)                          printf 'host' ;;
        rev_zone)                         printf 'zone' ;;
        admin_mail)                       printf 'mail' ;;
        dns_forwarders|dhcp_routers|dhcp_dns|dhcp_ntp) printf 'iplist' ;;
        dns_allow_query|dns_allow_xfer)   printf 'acl' ;;
        ttl|refresh|retry|expire|negttl|dhcp_lease|dhcp_maxlease) printf 'num' ;;
        ddns_key)                         printf 'host' ;;
        dhcp_file)                        printf 'path' ;;
        *) printf 'none' ;;
    esac
}

edit_field() {
    local i=$1 key=${FLD_KEY[$1]} type=${FLD_TYPE[$1]}
    local kind; kind=$(field_check_kind "$i")
    case $type in
        bool)   toggle_bool "$key"; return ;;
        choice) choice_menu "$i"; return ;;
        list)
            case $key in
                records)      records_menu ;;
                reservations) reserv_menu ;;
            esac
            return
            ;;
    esac
    local mask=0
    [[ $type == pass ]] && mask=1
    while :; do
        modal_edit "${FLD_LABEL[i]}" "${FLD_LABEL[i]} :" "${VAL[$key]}" "$mask" "${FLD_HINT[i]}" || return
        local v=$EDITED
        if [[ $kind != none ]] && ! validate_value "$kind" "$v"; then
            modal_message "$L_INVALID_T" "$VERR" "$C_ERR"
            continue
        fi
        [[ ${VAL[$key]} == "$v" ]] || DIRTY=1
        VAL[$key]=$v
        on_field_changed "$key"
        return
    done
}

# Ouvre la liste fermee d'un champ "choice".
choice_menu() {
    local i=$1 key=${FLD_KEY[$1]}
    local IFS=';'
    local -a opts=(${FLD_OPTS[$i]})
    IFS=$' \t\n'
    (( ${#opts[@]} == 0 )) && return
    LM_LABEL=("${opts[@]}"); LM_STATE=(); LM_SEL=0
    local j
    for (( j = 0; j < ${#opts[@]}; j++ )); do
        [[ ${opts[j]} == "${VAL[$key]}" ]] && LM_SEL=$j
    done
    LM_ACT=""
    if list_menu "${FLD_LABEL[i]}" "$L_MENU_PICK" && [[ -z $LM_ACT ]] && (( LM_SEL >= 0 )); then
        [[ ${VAL[$key]} == "${opts[LM_SEL]}" ]] || DIRTY=1
        VAL[$key]=${opts[LM_SEL]}
        on_field_changed "$key"
    fi
    LM_ACT=""
}

# Quelques champs en entrainent d'autres : on propose la mise a jour plutot que
# de laisser une configuration incoherente.
on_field_changed() {
    case $1 in
        iface)
            local ip pfx
            ip=$(iface_ip "${VAL[iface]}")
            pfx=$(iface_prefix "${VAL[iface]}")
            if [[ -n $ip ]]; then
                VAL[server_ip]=$ip
                [[ $pfx =~ ^[0-9]+$ ]] && VAL[netmask]=$(prefix_to_mask "$pfx")
                VAL[dhcp_iface]=${VAL[iface]}
                recompute_derived
            fi
            ;;
        server_ip|netmask)
            recompute_derived
            ;;
        domain)
            VAL[dhcp_domain]=${VAL[domain]}
            ;;
    esac
}

# Recalcule sans rien demander les valeurs strictement deduites : reseau,
# diffusion et zone inverse.
recompute_derived() {
    local net
    net=$(network_of "${VAL[server_ip]}" "${VAL[netmask]}") || return 0
    [[ -z $net ]] && return 0
    VAL[dhcp_subnet]=$net
    VAL[dhcp_mask]=${VAL[netmask]}
    VAL[dhcp_bcast]=$(broadcast_of "${VAL[server_ip]}" "${VAL[netmask]}")
    VAL[rev_zone]=$(rev_zone_of "$net" "${VAL[netmask]}")
    [[ -z ${VAL[dhcp_dns]} ]] && VAL[dhcp_dns]=${VAL[server_ip]}
}

select_field_row() {
    local key=$1 i idx
    build_rows
    for (( i = 0; i < ${#VR_TYPE[@]}; i++ )); do
        [[ ${VR_TYPE[i]} == fld ]] || continue
        idx=${VR_IDX[i]}
        if [[ ${FLD_KEY[idx]} == "$key" ]]; then SEL=$i; adjust_scroll; return; fi
    done
}

# Les lignes du formulaire et la barre de boutons forment une seule colonne :
# la barre entiere compte pour une position, le choix du bouton se fait ensuite
# avec les fleches gauche et droite.
move_sel() {
    local dir=$1 n=${#VR_TYPE[@]} i=$SEL
    while :; do
        i=$(( i + dir ))
        (( i < 0 )) && return
        (( i > n )) && return
        if (( i == n )); then SEL=$n; return; fi
        [[ ${VR_TYPE[i]} == gap ]] && continue
        SEL=$i; return
    done
}

# move_btn <sens 1|-1>
move_btn() {
    local nb=${#BTN_LABEL[@]}
    (( nb == 0 )) && return
    BTN_CUR=$(( (BTN_CUR + $1 + nb) % nb ))
}

#==============================================================================
#  13. ECRANS DE TRAITEMENT (TUX + BARRE DE PROGRESSION)
#==============================================================================

ANIM_MODE="install"    # install | apply | remove
ANIM_TITLE=""
STEP_LABEL=""
PCT=0
FRAME=0
ANIM_Y=0; ANIM_X=0; ANIM_W=0; ANIM_H=0
TUX_Y=0; GROUND_Y=0; LABEL_Y=0; BAR_Y=0; INFO_Y=0; TITLE_Y=0
ANIM_INFO=""

anim_layout() {
    ANIM_X=3
    ANIM_W=$(( COLS - 4 ))
    (( ANIM_W > 96 )) && { ANIM_W=96; ANIM_X=$(( (COLS - ANIM_W) / 2 + 1 )); }
    ANIM_Y=2
    local h=$(( ROWS - 3 ))
    ANIM_H=$h
    local inner_y=$(( ANIM_Y + 1 ))
    local content=13
    local free=$(( h - 2 - content ))
    (( free < 0 )) && free=0
    local top=$(( free / 2 ))
    TUX_Y=$(( inner_y + top ))
    GROUND_Y=$(( TUX_Y + TUX_H ))
    TITLE_Y=$(( GROUND_Y + 2 ))
    LABEL_Y=$(( TITLE_Y + 1 ))
    BAR_Y=$(( LABEL_Y + 1 ))
    INFO_Y=$(( BAR_Y + 1 ))
}

anim_begin() {
    ANIM_MODE=$1
    if (( CLI_MODE )); then
        ANIM_LAST=""
        case $ANIM_MODE in
            install) printf '\n== %s\n' "$L_ANIM_INST_TITLE" ;;
            apply)   printf '\n== %s\n' "$L_ANIM_APPLY_TITLE" ;;
            remove)  printf '\n== %s\n' "$L_ANIM_REM_TITLE" ;;
        esac
        return
    fi
    case $ANIM_MODE in
        install) ANIM_TITLE="$L_ANIM_INST_TITLE" ;;
        apply)   ANIM_TITLE="$L_ANIM_APPLY_TITLE" ;;
        remove)  ANIM_TITLE="$L_ANIM_REM_TITLE" ;;
        *)       ANIM_TITLE="$L_ANIM_WORK_TITLE" ;;
    esac
    compute_layout
    anim_layout
    BUF=$'\e[2J'
    draw_box "$ANIM_Y" "$ANIM_X" "$ANIM_H" "$ANIM_W" "$ANIM_TITLE" "$C_FRAME_ON"
    pad_str " $(printf "$L_ANIM_LOG" "$LOGFILE")" "$COLS"
    put "$ROWS" 1 "${C_MUTED}${PAD}${C_RESET}"
    printf '%s' "$BUF"
    RESIZED=0
    anim_tick
}

ANIM_LAST=""

anim_tick() {
    # En ligne de commande, une ligne par etape suffit : pas de curseur a
    # deplacer, pas de Tux a promener.
    if (( CLI_MODE )); then
        [[ $STEP_LABEL == "$ANIM_LAST" ]] && return
        ANIM_LAST=$STEP_LABEL
        printf '  [%3d%%] %s\n' "$PCT" "$STEP_LABEL"
        return
    fi
    (( RESIZED )) && { anim_begin "$ANIM_MODE"; return; }
    FRAME=$(( (FRAME + 1) % 4 ))
    local inner=$(( ANIM_W - 4 ))
    local ix=$(( ANIM_X + 2 ))
    local i x

    # Tux avance au rythme de la progression reelle
    local run=$(( inner - TUX_W - 2 ))
    (( run < 0 )) && run=0
    x=$(( ix + run * PCT / 100 ))
    (( x < ix )) && x=$ix

    BUF=""
    for (( i = 0; i < TUX_H; i++ )); do
        tux_line "$FRAME" "$i"
        local art=$TUXL
        local before=$(( x - ix ))
        printf -v PAD '%*s' "$before" ''
        local pre=$PAD
        pad_str "$art" $(( inner - before ))
        local col=$C_TUX
        (( i >= TUX_H - 1 )) && col=$C_TUX_FEET
        put $(( TUX_Y + i )) "$ix" "${pre}${col}${PAD}${C_RESET}"
    done

    rep_char "$GROUND" "$inner"
    put "$GROUND_Y" "$ix" "${C_FRAME}${REPC}${C_RESET}"

    local dots=""
    case $FRAME in
        0) dots="" ;;
        1) dots="." ;;
        2) dots=".." ;;
        *) dots="..." ;;
    esac
    local ptitle="${ANIM_TITLE}${dots}"
    local px=$(( ix + (inner - ${#ptitle}) / 2 ))
    (( px < ix )) && px=$ix
    printf -v PAD '%*s' "$inner" ''
    put "$TITLE_Y" "$ix" "$PAD"
    put "$TITLE_Y" "$px" "${C_BOLD}${C_TITLE}${ptitle}${C_RESET}"

    pad_str "$STEP_LABEL" "$inner"
    put "$LABEL_Y" "$ix" "${C_LABEL}${PAD}${C_RESET}"

    draw_bar "$BAR_Y" "$ix" "$inner" "$PCT"

    pad_str "$ANIM_INFO" "$inner"
    put "$INFO_Y" "$ix" "${C_MUTED}${PAD}${C_RESET}"

    printf '%s' "$BUF"
}

# Tux encaisse l'erreur et s'effondre, la barre se fige en rouge a l'endroit
# exact ou l'etape a lache.
anim_death() {
    (( CLI_MODE )) && return 0
    (( ANIM_W > 2 )) || return 0
    local inner=$(( ANIM_W - 4 ))
    local ix=$(( ANIM_X + 2 ))
    local f i x before pre art

    local run=$(( inner - TUX_W - 2 ))
    (( run < 0 )) && run=0
    x=$(( ix + run * PCT / 100 ))
    (( x < ix )) && x=$ix
    before=$(( x - ix ))

    local bar_save=$C_BAR
    C_BAR=$C_ERR

    local ptitle="$L_ANIM_FAIL_PHASE"
    local px=$(( ix + (inner - ${#ptitle}) / 2 ))
    (( px < ix )) && px=$ix

    for (( f = 0; f < 4; f++ )); do
        BUF=""
        for (( i = 0; i < TUX_H; i++ )); do
            tux_death_line "$f" "$i"
            art=$TUXL
            printf -v PAD '%*s' "$before" ''
            pre=$PAD
            pad_str "$art" $(( inner - before ))
            put $(( TUX_Y + i )) "$ix" "${pre}${C_ERR}${PAD}${C_RESET}"
        done
        printf -v PAD '%*s' "$inner" ''
        put "$TITLE_Y" "$ix" "$PAD"
        put "$TITLE_Y" "$px" "${C_BOLD}${C_ERR}${ptitle}${C_RESET}"
        pad_str "$STEP_LABEL" "$inner"
        put "$LABEL_Y" "$ix" "${C_ERR}${PAD}${C_RESET}"
        draw_bar "$BAR_Y" "$ix" "$inner" "$PCT"
        pad_str "" "$inner"
        put "$INFO_Y" "$ix" "$PAD"
        printf '%s' "$BUF"
        sleep 0.28
    done

    C_BAR=$bar_save
    sleep 0.4
}

#==============================================================================
#  14. SONDES DE PROGRESSION
#==============================================================================

probe_apt() {
    local dl=-1 pm=-1 line _a _b p
    if [[ -s $APT_STATUS ]]; then
        line=$(grep '^dlstatus:' "$APT_STATUS" 2>/dev/null | tail -n1)
        if [[ -n $line ]]; then
            IFS=: read -r _a _b p _ <<<"$line"; dl=${p%%.*}
        fi
        line=$(grep '^pmstatus:' "$APT_STATUS" 2>/dev/null | tail -n1)
        if [[ -n $line ]]; then
            IFS=: read -r _a _b p _ <<<"$line"; pm=${p%%.*}
        fi
    fi
    [[ $dl =~ ^[0-9]+$ ]] || dl=-1
    [[ $pm =~ ^[0-9]+$ ]] || pm=-1
    if (( pm >= 0 )); then
        printf '%d' $(( 40 + pm * 60 / 100 ))
    elif (( dl >= 0 )); then
        printf '%d' $(( dl * 40 / 100 ))
    else
        printf '0'
    fi
}

probe_apt_update() {
    local line _a _b p=0 q n m f
    [[ -s $APT_STATUS ]] || { printf '0'; return; }
    line=$(grep '^dlstatus:' "$APT_STATUS" 2>/dev/null | tail -n1)
    [[ -z $line ]] && { printf '0'; return; }
    IFS=: read -r _a _b q _ <<<"$line"
    q=${q%%.*}
    [[ $q =~ ^[0-9]+$ ]] && p=$q
    if [[ $line =~ file[[:space:]]+([0-9]+)[[:space:]]+of[[:space:]]+([0-9]+) ]]; then
        n=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
        if (( m > 0 )); then
            f=$(( n * 100 / m ))
            (( f > p )) && p=$f
        fi
    fi
    printf '%d' "$p"
}

# Attente du verrou apt : faute de mieux, le temps ecoule sur le temps maximum.
probe_apt_lock() {
    local e=$(( SECONDS - APT_LOCK_T0 ))
    (( APT_LOCK_MAX > 0 )) || { printf '0'; return; }
    e=$(( e * 100 / APT_LOCK_MAX ))
    (( e < 0 )) && e=0
    (( e > 100 )) && e=100
    printf '%d' "$e"
}

#==============================================================================
#  15. MOTEUR D'EXECUTION DES ETAPES
#==============================================================================

log_line() { printf '%s\n' "$*" >>"$LOGFILE" 2>/dev/null; }

log_start() {
    : >>"$LOGFILE" 2>/dev/null
    chmod 600 "$LOGFILE" 2>/dev/null
    printf '\n########## %s : %s ##########\n' "$(date '+%F %T')" "$1" >>"$LOGFILE" 2>/dev/null
}

# step_run <libelle> <pct debut> <pct fin> <sonde|-> <commande...>
step_run() {
    local label=$1 ps=$2 pe=$3 probe=$4
    shift 4
    STEP_LABEL=$label
    PCT=$ps
    : >"$STEP_LOG"
    printf '\n===== %s : %s =====\n' "$(date '+%F %T')" "$label" >>"$LOGFILE" 2>/dev/null
    ( "$@" ) >>"$STEP_LOG" 2>&1 &
    local pid=$! sub rc
    while kill -0 "$pid" 2>/dev/null; do
        sub=0
        [[ $probe != "-" ]] && sub=$("$probe")
        [[ $sub =~ ^[0-9]+$ ]] || sub=0
        (( sub > 100 )) && sub=100
        PCT=$(( ps + (pe - ps) * sub / 100 ))
        anim_tick
        sleep 0.12
    done
    wait "$pid"; rc=$?
    cat "$STEP_LOG" >>"$LOGFILE" 2>/dev/null
    PCT=$pe
    anim_tick
    return $rc
}

# Etape sautee : la barre avance quand meme pour rester lisible.
step_skip() {
    STEP_LABEL=$1
    PCT=$2
    log_line "-- saute : $1"
    anim_tick
}

# die_step <message> : joue l'agonie de Tux, montre l'erreur, rend la main.
# Contrairement a un installateur, ce script ne quitte pas : on revient a
# l'ecran principal pour corriger et relancer.
die_step() {
    local msg=$1 tail_log
    # Douze lignes : de quoi montrer a la fois le motif de l'echec et l'etat
    # du chemin mis en cause, que les taches tracent desormais l'un apres
    # l'autre.
    tail_log=$(tail -n 12 "$STEP_LOG" 2>/dev/null | cut -c1-72)
    log_line "ECHEC : $msg (etape : ${STEP_LABEL:-?}, progression : ${PCT:-0}%)"
    if (( CLI_MODE )); then
        printf '%s\n' "$msg" >&2
        printf '%s\n' "${tail_log:-$L_FAIL_NONE}" >&2
        printf "$L_FAIL_LOG\n" "$LOGFILE" >&2
        return 1
    fi
    anim_death
    compute_layout
    modal_message "$L_FAIL_T" \
"$msg

$L_FAIL_LOGTAIL
${tail_log:-$L_FAIL_NONE}

$(printf "$L_FAIL_LOG" "$LOGFILE")" "$C_ERR"
    return 1
}

# Fin de traitement reussie.
anim_done() {
    STEP_LABEL="$1"
    PCT=100
    anim_tick
    (( CLI_MODE )) || sleep 0.6
}

#==============================================================================
#  16. OUTILS DE LISTE (enregistrements DNS et reservations DHCP)
#
#  Les deux listes sont stockees dans un seul champ texte :
#     "nom|type|valeur;nom|type|valeur"      pour les enregistrements
#     "nom|mac|ip;nom|mac|ip"                pour les reservations
#  Aucun element ne peut contenir ni ';' ni '|' : la saisie les refuse.
#==============================================================================

declare -a LIST_ITEMS

# parse_list <chaine> -> LIST_ITEMS
parse_list() {
    LIST_ITEMS=()
    local s=$1
    [[ -z $s ]] && return 0
    local IFS=';'
    local -a a=($s)
    IFS=$' \t\n'
    local e
    for e in "${a[@]}"; do
        [[ -n $e ]] && LIST_ITEMS+=("$e")
    done
}

# join_list -> chaine (depuis LIST_ITEMS)
join_list() {
    local out="" e
    for e in "${LIST_ITEMS[@]}"; do
        [[ -z $out ]] && out="$e" || out="$out;$e"
    done
    printf '%s' "$out"
}

#==============================================================================
#  17. TACHES : PAQUETS
#==============================================================================

APT_LOCK_MAX=180        # attente maximale du verrou apt, en secondes
APT_LOCK_T0=0

# Le verrou de dpkg est pose avec fcntl() : flock(1) ne le voit pas. On se
# rabat donc sur fuser quand il est la, sinon sur les noms de processus
# (unattended-upgr est tronque a 15 caracteres par le noyau).
apt_lock_busy() {
    if command -v fuser >/dev/null 2>&1; then
        fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
              /var/lib/apt/lists/lock >/dev/null 2>&1 && return 0
        return 1
    fi
    pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1
}

do_wait_apt_lock() {
    local waited=0
    while apt_lock_busy; do
        (( waited >= APT_LOCK_MAX )) && {
            printf 'Verrou apt toujours pris apres %s s\n' "$APT_LOCK_MAX"
            return 0
        }
        sleep 2
        waited=$(( waited + 2 ))
    done
    return 0
}

do_apt_update() {
    : >"$APT_STATUS"
    apt-get -o APT::Status-Fd=3 update -qq 3>"$APT_STATUS"
}

do_apt_install() {
    : >"$APT_STATUS"
    apt-get -o APT::Status-Fd=3 -y -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold install "$@" 3>"$APT_STATUS"
}

# Paquets DNS : bind9 et ses outils. dnsutils a ete renomme bind9-dnsutils sur
# les versions recentes, on prend celui qui existe.
dns_packages() {
    local pkgs="bind9 bind9-utils"
    if pkg_known bind9-dnsutils; then pkgs="$pkgs bind9-dnsutils"
    elif pkg_known dnsutils; then pkgs="$pkgs dnsutils"; fi
    pkg_known bind9-doc && pkgs="$pkgs bind9-doc"
    printf '%s' "$pkgs"
}

do_install_dns() {
    local p; p=$(dns_packages)
    # shellcheck disable=SC2086
    do_apt_install $p
}

# Paquets DHCP : le serveur DHCPv4, plus le demon de mise a jour dynamique
# quand elle est demandee.
dhcp_packages() {
    local pkgs="kea-dhcp4-server"
    [[ ${VAL[ddns_enable]} == oui ]] && pkg_known kea-dhcp-ddns-server && \
        pkgs="$pkgs kea-dhcp-ddns-server"
    printf '%s' "$pkgs"
}

do_install_dhcp() {
    local p; p=$(dhcp_packages)
    # shellcheck disable=SC2086
    do_apt_install $p
}

#==============================================================================
#  18. TACHES : SAUVEGARDE DES FICHIERS EXISTANTS
#==============================================================================

BACKUP_STAMP=""

do_backup() {
    BACKUP_STAMP=$(date '+%Y%m%d-%H%M%S')
    local dst="$BACKUP_DIR/$BACKUP_STAMP"
    mkdir -p "$dst" || return 1
    chmod 700 "$BACKUP_DIR" 2>/dev/null
    local f
    for f in "$BIND_OPTIONS" "$BIND_LOCAL" "$BIND_DIR/named.conf" \
             "$KEA_CONF" "$KEA_D2_CONF" "$DDNS_KEY_FILE" "$CONF_FILE"; do
        [[ -f $f ]] && cp -a "$f" "$dst/$(basename "$f")" 2>/dev/null
    done
    if [[ -d $BIND_ZONE_DIR ]]; then
        mkdir -p "$dst/zones"
        cp -a "$BIND_ZONE_DIR"/. "$dst/zones/" 2>/dev/null
        rm -f "$dst/zones"/*.dnsdhcp-*.tmp 2>/dev/null
    fi
    printf 'Sauvegarde dans %s\n' "$dst"
    # on ne garde que les 20 dernieres sauvegardes
    local old
    while IFS= read -r old; do
        [[ -n $old && -d $old && $old == "$BACKUP_DIR"/* ]] || continue
        rm -rf "$old"
    done < <(ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | sort | head -n -20)
    return 0
}

#==============================================================================
#  18 bis. ECRITURE SURE DES FICHIERS GENERES
#
#  Une redirection "{ ... } > fichier" ne rate que si le fichier ne peut pas
#  etre ouvert. Si la generation s'arrete en cours de route, le shell rend
#  quand meme 0 et laisse un fichier tronque, voire vide, a sa place : l'etape
#  est declaree reussie et l'erreur ne remonte que bien plus tard, sous la
#  forme deroutante d'un named-checkconf ou d'un kea-dhcp4 -t qui bute sur un
#  fichier "introuvable". On ecrit donc toujours a cote, on verifie que la
#  derniere ligne attendue est bien la, puis on met en place d'un seul coup.
#==============================================================================

# num_or <valeur> <defaut> : toute valeur qui part dans un calcul passe par
# ici. Un champ vide couperait $(( )) et donc la generation, en plein milieu
# du fichier.
num_or() {
    [[ $1 =~ ^[0-9]+$ ]] && { printf '%s' "$1"; return 0; }
    printf '%s' "$2"
}

group_exists() {
    getent group "$1" >/dev/null 2>&1 && return 0
    grep -q "^$1:" /etc/group 2>/dev/null
}

user_exists() {
    getent passwd "$1" >/dev/null 2>&1 && return 0
    grep -q "^$1:" /etc/passwd 2>/dev/null
}

# Fichier de travail place dans le repertoire de destination : meme systeme de
# fichiers, donc un mv reellement atomique.
tmp_for() { printf '%s.dnsdhcp-%s.tmp' "$1" "$$"; }

# publish_file <temporaire> <destination> <mode> [proprietaire]
publish_file() {
    local tmp=$1 dst=$2 mode=$3 owner=${4:-} last
    if [[ ! -s $tmp ]]; then
        printf "Generation vide : %s n'a pas ete ecrit\n" "$dst"
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    last=$(tail -n 3 "$tmp" 2>/dev/null | tr -d '[:space:]')
    if [[ $last != *"$GEN_END" ]]; then
        printf "Generation interrompue : %s est incomplet, rien n'a ete remplace\n" "$dst"
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    if [[ -d $dst ]]; then
        # mv deposerait le fichier a l'interieur au lieu de remplacer.
        printf '%s est un repertoire, pas un fichier de configuration\n' "$dst"
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null
    [[ -n $owner ]] && chown "$owner" "$tmp" 2>/dev/null
    if ! mv -f "$tmp" "$dst" 2>&1; then
        printf 'Mise en place impossible : %s\n' "$dst"
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    if [[ ! -s $dst || ! -r $dst ]]; then
        printf "Apres ecriture, %s est absent, vide ou illisible\n" "$dst"
        return 1
    fi
    return 0
}

# file_ready <fichier> : dit precisement ce qui manque avant d'appeler un
# controleur de syntaxe, la ou l'outil se contente d'un "Unable to open file"
# qui ne distingue pas absent, vide et illisible.
file_ready() {
    local f=$1
    if [[ ! -e $f ]]; then printf '%s est absent\n' "$f"; return 1; fi
    if [[ -d $f ]]; then printf '%s est un repertoire\n' "$f"; return 1; fi
    if [[ ! -s $f ]]; then printf '%s est vide\n' "$f"; return 1; fi
    if [[ ! -r $f ]]; then printf "%s n'est pas lisible\n" "$f"; return 1; fi
    return 0
}

# report_path <fichier> : trace ce que le disque montre vraiment. Le journal
# suffit alors a trancher entre droits, place libre et fichier jamais ecrit.
report_path() {
    local f=$1 d
    d=$(dirname "$f")
    printf 'Etat du chemin %s :\n' "$f"
    ls -ld "$d" 2>&1 | sed 's/^/  /'
    ls -l "$f" 2>&1 | sed 's/^/  /'
    command -v df >/dev/null 2>&1 && df -h "$d" 2>/dev/null | tail -n 1 | sed 's/^/  /'
    return 0
}

# ensure_dir <repertoire> : un mkdir qui explique son echec.
ensure_dir() {
    mkdir -p "$1" 2>/dev/null && return 0
    printf 'Repertoire inaccessible : %s\n' "$1"
    report_path "$1"
    return 1
}

#==============================================================================
#  19. TACHES : CONFIGURATION DE BIND9
#==============================================================================

# acl_block <liste ";"> -> "a; b; c;" au format BIND
acl_block() {
    local l=${1//;/ } i out=""
    for i in $l; do
        [[ -z $i ]] && continue
        out="$out $i;"
    done
    [[ -z $out ]] && out=" none;"
    printf '%s' "$out"
}

# next_serial <fichier de zone> : numero de serie YYYYMMDDnn, toujours croissant
next_serial() {
    local f=$1 today old n
    today=$(date +%Y%m%d)
    old=""
    [[ -r $f ]] && old=$(sed -n 's/^[[:space:]]*\([0-9]\{8,12\}\)[[:space:]]*;[[:space:]]*[Ss]erial.*/\1/p' "$f" | head -n1)
    if [[ $old =~ ^[0-9]+$ ]]; then
        if (( old >= today * 100 )); then
            printf '%s' $(( old + 1 ))
            return
        fi
    fi
    printf '%s01' "$today"
}

do_ddns_key() {
    [[ ${VAL[ddns_enable]} == oui ]] || return 0
    if [[ -s $DDNS_KEY_FILE ]] && grep -q "key \"${VAL[ddns_key]}\"" "$DDNS_KEY_FILE"; then
        printf 'Cle DDNS deja presente\n'
        return 0
    fi
    local secret=""
    if command -v tsig-keygen >/dev/null 2>&1; then
        tsig-keygen -a "${VAL[ddns_algo]}" "${VAL[ddns_key]}" >"$DDNS_KEY_FILE" || return 1
    else
        secret=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
        cat >"$DDNS_KEY_FILE" <<EOF
key "${VAL[ddns_key]}" {
    algorithm ${VAL[ddns_algo]};
    secret "$secret";
};
EOF
    fi
    chown root:bind "$DDNS_KEY_FILE" 2>/dev/null
    chmod 640 "$DDNS_KEY_FILE" 2>/dev/null
    return 0
}

do_bind_options() {
    local fwd rec dnssec v6 ver
    fwd=$(acl_block "${VAL[dns_forwarders]}")
    rec="no"; [[ ${VAL[dns_recursion]} == oui ]] && rec="yes"
    dnssec="no"; [[ ${VAL[dns_dnssec]} == oui ]] && dnssec="auto"
    v6="none"; [[ ${VAL[dns_listen6]} == oui ]] && v6="any"

    ensure_dir "$BIND_DIR" || return 1
    local tmp; tmp=$(tmp_for "$BIND_OPTIONS")
    {
        printf '%s\n' "$GEN_MARK"
        printf '// %s\n\n' "$(date '+%F %T')"
        printf 'options {\n'
        printf '    directory "/var/cache/bind";\n\n'
        printf '    listen-on { any; };\n'
        printf '    listen-on-v6 { %s; };\n\n' "$v6"
        printf '    forwarders {%s };\n' "$fwd"
        [[ ${VAL[dns_forward_only]} == oui ]] && printf '    forward only;\n'
        printf '\n'
        printf '    recursion %s;\n' "$rec"
        printf '    allow-query {%s };\n' "$(acl_block "${VAL[dns_allow_query]}")"
        printf '    allow-transfer {%s };\n' "$(acl_block "${VAL[dns_allow_xfer]}")"
        printf '    allow-recursion {%s };\n\n' "$(acl_block "${VAL[dns_allow_query]}")"
        printf '    dnssec-validation %s;\n' "$dnssec"
        if [[ ${VAL[dns_hide_ver]} == oui ]]; then
            printf '    version none;\n'
            printf '    hostname none;\n'
            printf '    server-id none;\n'
        fi
        printf '\n    auth-nxdomain no;\n'
        printf '};\n'
        printf '// %s\n' "$GEN_END"
    } >"$tmp" || { rm -f "$tmp" 2>/dev/null; report_path "$BIND_OPTIONS"; return 1; }
    publish_file "$tmp" "$BIND_OPTIONS" 644 || { report_path "$BIND_OPTIONS"; return 1; }
    return 0
}

do_bind_local() {
    local dom=${VAL[domain]} rev=${VAL[rev_zone]}
    local upd="none"
    [[ ${VAL[ddns_enable]} == oui ]] && upd="key \"${VAL[ddns_key]}\""

    ensure_dir "$BIND_DIR" || return 1
    local tmp; tmp=$(tmp_for "$BIND_LOCAL")
    {
        printf '%s\n' "$GEN_MARK"
        printf '// %s\n\n' "$(date '+%F %T')"
        if [[ ${VAL[ddns_enable]} == oui ]]; then
            printf 'include "%s";\n\n' "$DDNS_KEY_FILE"
        fi
        if [[ ${VAL[dns_logging]} == oui ]]; then
            cat <<EOF
logging {
    channel dnsdhcp_log {
        file "$BIND_LOGDIR/named.log" versions 5 size 10m;
        severity info;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    category default  { dnsdhcp_log; };
    category security { dnsdhcp_log; };
    category update   { dnsdhcp_log; };
    category xfer-in  { dnsdhcp_log; };
    category xfer-out { dnsdhcp_log; };
    category lame-servers { null; };
};

EOF
        fi
        if [[ ${VAL[dns_forward]} == oui ]]; then
            cat <<EOF
zone "$dom" {
    type master;
    file "$BIND_ZONE_DIR/db.$dom";
    allow-update { $upd; };
    notify no;
};

EOF
        fi
        if [[ ${VAL[dns_reverse]} == oui && -n $rev ]]; then
            cat <<EOF
zone "$rev" {
    type master;
    file "$BIND_ZONE_DIR/db.$rev";
    allow-update { $upd; };
    notify no;
};
EOF
        fi
        printf '// %s\n' "$GEN_END"
    } >"$tmp" || { rm -f "$tmp" 2>/dev/null; report_path "$BIND_LOCAL"; return 1; }
    publish_file "$tmp" "$BIND_LOCAL" 644 || { report_path "$BIND_LOCAL"; return 1; }

    if [[ ${VAL[dns_logging]} == oui ]]; then
        mkdir -p "$BIND_LOGDIR"
        chown bind:bind "$BIND_LOGDIR" 2>/dev/null
        chmod 755 "$BIND_LOGDIR"
    fi
    return 0
}

# Ecrit les deux fichiers de zone a partir de la liste d'enregistrements.
do_zone_files() {
    local dom=${VAL[domain]} rev=${VAL[rev_zone]} ns=${VAL[ns_name]}
    local ip=${VAL[server_ip]} mail=${VAL[admin_mail]}
    local ffile="$BIND_ZONE_DIR/db.$dom"
    local rfile="$BIND_ZONE_DIR/db.$rev"
    local serial name type value owner

    ensure_dir "$BIND_ZONE_DIR" || return 1
    local tmp

    if [[ ${VAL[dns_forward]} == oui ]]; then
        serial=$(next_serial "$ffile")
        tmp=$(tmp_for "$ffile")
        {
            printf '; %s\n' "${GEN_MARK#\# }"
            printf '; %s\n' "$(date '+%F %T')"
            printf '$TTL %s\n' "${VAL[ttl]}"
            printf '@   IN  SOA %s.%s. %s.%s. (\n' "$ns" "$dom" "$mail" "$dom"
            printf '            %-10s ; Serial\n' "$serial"
            printf '            %-10s ; Refresh\n' "${VAL[refresh]}"
            printf '            %-10s ; Retry\n' "${VAL[retry]}"
            printf '            %-10s ; Expire\n' "${VAL[expire]}"
            printf '            %-10s ) ; Negative Cache TTL\n' "${VAL[negttl]}"
            printf ';\n'
            printf '@       IN  NS      %s.%s.\n' "$ns" "$dom"
            printf '%-15s IN  A       %s\n' "$ns" "$ip"
            printf '@       IN  A       %s\n' "$ip"
            parse_list "${VAL[records]}"
            local e
            for e in "${LIST_ITEMS[@]}"; do
                IFS='|' read -r name type value <<<"$e"
                [[ -z $name || -z $type || -z $value ]] && continue
                case $type in
                    A|AAAA|CNAME|NS|PTR)
                        printf '%-15s IN  %-7s %s\n' "$name" "$type" "$value" ;;
                    MX)
                        # valeur attendue : "priorite cible"
                        printf '%-15s IN  MX      %s\n' "$name" "$value" ;;
                    TXT)
                        printf '%-15s IN  TXT     "%s"\n' "$name" "$value" ;;
                    SRV)
                        printf '%-15s IN  SRV     %s\n' "$name" "$value" ;;
                esac
            done
            # une reservation DHCP est une adresse fixe : elle a sa place dans
            # la zone directe, sans quoi le nom ne se resout pas
            if [[ ${VAL[dhcp_enable]} == oui ]]; then
                local rmac
                parse_list "${VAL[reservations]}"
                for e in "${LIST_ITEMS[@]}"; do
                    IFS='|' read -r name rmac value <<<"$e"
                    [[ -n $name && -n $value ]] || continue
                    valid_ip "$value" || continue
                    printf '%-15s IN  A       %s\n' "$name" "$value"
                done
            fi
            printf '; %s\n' "$GEN_END"
        } >"$tmp" || { rm -f "$tmp" 2>/dev/null; report_path "$ffile"; return 1; }
        publish_file "$tmp" "$ffile" 644 root:bind || { report_path "$ffile"; return 1; }
    fi

    if [[ ${VAL[dns_reverse]} == oui && -n $rev ]]; then
        serial=$(next_serial "$rfile")
        tmp=$(tmp_for "$rfile")
        {
            printf '; %s\n' "${GEN_MARK#\# }"
            printf '; %s\n' "$(date '+%F %T')"
            printf '$TTL %s\n' "${VAL[ttl]}"
            printf '@   IN  SOA %s.%s. %s.%s. (\n' "$ns" "$dom" "$mail" "$dom"
            printf '            %-10s ; Serial\n' "$serial"
            printf '            %-10s ; Refresh\n' "${VAL[refresh]}"
            printf '            %-10s ; Retry\n' "${VAL[retry]}"
            printf '            %-10s ; Expire\n' "${VAL[expire]}"
            printf '            %-10s ) ; Negative Cache TTL\n' "${VAL[negttl]}"
            printf ';\n'
            printf '@       IN  NS      %s.%s.\n' "$ns" "$dom"
            owner=$(ptr_owner "$ip" "$rev")
            [[ -n $owner ]] && printf '%-11s IN  PTR     %s.%s.\n' "$owner" "$ns" "$dom"
            parse_list "${VAL[records]}"
            local e
            for e in "${LIST_ITEMS[@]}"; do
                IFS='|' read -r name type value <<<"$e"
                [[ $type == A ]] || continue
                valid_ip "$value" || continue
                owner=$(ptr_owner "$value" "$rev")
                [[ -z $owner ]] && continue
                printf '%-11s IN  PTR     %s.%s.\n' "$owner" "$name" "$dom"
            done
            # les reservations DHCP meritent aussi leur PTR : une adresse
            # fixe distribuee par DHCP se resout comme un hote statique
            if [[ ${VAL[dhcp_enable]} == oui ]]; then
                local rmac
                parse_list "${VAL[reservations]}"
                for e in "${LIST_ITEMS[@]}"; do
                    IFS='|' read -r name rmac value <<<"$e"
                    valid_ip "$value" || continue
                    owner=$(ptr_owner "$value" "$rev")
                    [[ -z $owner ]] && continue
                    printf '%-11s IN  PTR     %s.%s.\n' "$owner" "$name" "$dom"
                done
            fi
            printf '; %s\n' "$GEN_END"
        } >"$tmp" || { rm -f "$tmp" 2>/dev/null; report_path "$rfile"; return 1; }
        publish_file "$tmp" "$rfile" 644 root:bind || { report_path "$rfile"; return 1; }
    fi

    chown root:bind "$BIND_ZONE_DIR" 2>/dev/null
    return 0
}

# check_zone <zone> <fichier> : named-checkzone sur un fichier absent rend une
# erreur laconique. On verifie donc le fichier d'abord.
check_zone() {
    local zone=$1 f=$2
    if ! file_ready "$f"; then
        report_path "$f"
        return 1
    fi
    named-checkzone "$zone" "$f"
}

do_check_bind() {
    local rc=0
    if ! command -v named-checkconf >/dev/null 2>&1; then
        printf "named-checkconf est introuvable : BIND9 n'est pas installe\n"
        return 1
    fi
    file_ready "$BIND_OPTIONS" || { report_path "$BIND_OPTIONS"; rc=1; }
    file_ready "$BIND_LOCAL"   || { report_path "$BIND_LOCAL"; rc=1; }
    named-checkconf || rc=1
    if [[ ${VAL[dns_forward]} == oui ]]; then
        check_zone "${VAL[domain]}" "$BIND_ZONE_DIR/db.${VAL[domain]}" || rc=1
    fi
    if [[ ${VAL[dns_reverse]} == oui && -n ${VAL[rev_zone]} ]]; then
        check_zone "${VAL[rev_zone]}" "$BIND_ZONE_DIR/db.${VAL[rev_zone]}" || rc=1
    fi
    return $rc
}

#==============================================================================
#  20. TACHES : CONFIGURATION DE KEA DHCP4
#
#  La configuration de Kea est du JSON : chaque virgule compte. Les listes sont
#  donc assemblees dans un tableau puis rendues par json_list(), qui place les
#  separateurs. Kea accepte les commentaires de style C++, ce qui permet de
#  marquer les fichiers generes sans casser l'analyse.
#==============================================================================

# json_esc <texte> : echappe ce qui ne peut pas rester tel quel dans une chaine
json_esc() {
    local v=$1
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    printf '%s' "$v"
}

# csv_list <liste ";"> -> "a, b, c", format attendu par les options DHCP
csv_list() {
    local l=${1//;/ } i out=""
    for i in $l; do
        [[ -z $i ]] && continue
        [[ -z $out ]] && out="$i" || out="$out, $i"
    done
    printf '%s' "$out"
}

# json_list <indentation> <element...> : imprime les elements separes par des
# virgules, sans virgule finale.
json_list() {
    local ind=$1; shift
    local n=$# i=1 e
    for e in "$@"; do
        if (( i < n )); then
            printf '%s%s,\n' "$ind" "$e"
        else
            printf '%s%s\n' "$ind" "$e"
        fi
        i=$(( i + 1 ))
    done
}

# Options DHCP annoncees, communes au sous-reseau -> tableau KEA_OPTS
build_kea_options() {
    KEA_OPTS=()
    local v
    v=$(csv_list "${VAL[dhcp_routers]}")
    [[ -n $v ]] && KEA_OPTS+=("{ \"name\": \"routers\", \"data\": \"$(json_esc "$v")\" }")
    v=$(csv_list "${VAL[dhcp_dns]}")
    [[ -n $v ]] && KEA_OPTS+=("{ \"name\": \"domain-name-servers\", \"data\": \"$(json_esc "$v")\" }")
    [[ -n ${VAL[dhcp_domain]} ]] && \
        KEA_OPTS+=("{ \"name\": \"domain-name\", \"data\": \"$(json_esc "${VAL[dhcp_domain]}")\" }")
    [[ -n ${VAL[dhcp_bcast]} ]] && \
        KEA_OPTS+=("{ \"name\": \"broadcast-address\", \"data\": \"${VAL[dhcp_bcast]}\" }")
    v=$(csv_list "${VAL[dhcp_ntp]}")
    [[ -n $v ]] && KEA_OPTS+=("{ \"name\": \"ntp-servers\", \"data\": \"$(json_esc "$v")\" }")
    return 0
}

# Reservations d'adresses -> tableau KEA_RES
build_kea_reservations() {
    KEA_RES=()
    local e name mac ip
    parse_list "${VAL[reservations]}"
    for e in "${LIST_ITEMS[@]}"; do
        IFS='|' read -r name mac ip <<<"$e"
        [[ -n $name && -n $mac && -n $ip ]] || continue
        KEA_RES+=("{ \"hw-address\": \"$mac\", \"ip-address\": \"$ip\", \"hostname\": \"$(json_esc "$name")\" }")
    done
    return 0
}

do_kea_conf() {
    local pfx pool okey lease maxlease tmp
    # La version de Kea est lue une seule fois, hors substitution, pour que la
    # mise en cache serve aussi aux appels suivants de cette etape.
    detect_kea_version
    # Chaque valeur qui part dans un calcul est bornee : un champ vide ferait
    # echouer $(( )) et laisserait le fichier coupe en deux.
    pfx=$(num_or "$(mask_to_prefix "${VAL[dhcp_mask]}")" 24)
    (( pfx < 1 || pfx > 32 )) && pfx=24
    lease=$(num_or "${VAL[dhcp_lease]}" 600)
    (( lease < 60 )) && lease=60
    maxlease=$(num_or "${VAL[dhcp_maxlease]}" 7200)
    (( maxlease < lease )) && maxlease=$lease
    pool="${VAL[range_start]} - ${VAL[range_end]}"
    okey=$(kea_output_key)

    local -a KEA_OPTS KEA_RES
    build_kea_options
    build_kea_reservations

    # Servir uniquement les machines reservees se fait en reservant la plage a
    # la classe integree KNOWN : Kea n'a pas d'equivalent direct de
    # "deny unknown-clients".
    local pool_line="{ \"pool\": \"$pool\" }"
    [[ ${VAL[dhcp_deny]} == oui ]] && \
        pool_line="{ \"pool\": \"$pool\", \"client-class\": \"KNOWN\" }"

    ensure_dir "$KEA_DIR" || return 1
    ensure_dir "$(dirname "$KEA_LEASES")" || return 1
    ensure_dir "$KEA_LOGDIR" || return 1
    # Le service tourne sous _kea : baux et journaux doivent lui appartenir.
    if user_exists _kea; then
        chown _kea:_kea "$KEA_LOGDIR" "$(dirname "$KEA_LEASES")" 2>/dev/null
    fi

    tmp=$(tmp_for "$KEA_CONF")
    {
        printf '// %s\n' "${GEN_MARK#\# }"
        printf '// %s\n' "$(date '+%F %T')"
        printf '{\n"Dhcp4": {\n'

        printf '    "interfaces-config": {\n'
        printf '        "interfaces": [ "%s" ]\n' "$(json_esc "${VAL[dhcp_iface]}")"
        printf '    },\n\n'

        printf '    "control-socket": {\n'
        printf '        "socket-type": "unix",\n'
        printf '        "socket-name": "%s"\n' "$KEA_SOCKET"
        printf '    },\n\n'

        printf '    "lease-database": {\n'
        printf '        "type": "memfile",\n'
        printf '        "lfc-interval": 3600,\n'
        printf '        "name": "%s"\n' "$KEA_LEASES"
        printf '    },\n\n'

        printf '    "valid-lifetime": %s,\n' "$lease"
        printf '    "max-valid-lifetime": %s,\n' "$maxlease"
        printf '    "renew-timer": %s,\n' "$(( lease / 2 ))"
        printf '    "rebind-timer": %s,\n' "$(( lease * 7 / 8 ))"
        if [[ ${VAL[dhcp_auth]} == oui ]]; then
            printf '    "authoritative": true,\n'
        else
            printf '    "authoritative": false,\n'
        fi
        printf '\n'

        if [[ ${VAL[ddns_enable]} == oui ]]; then
            printf '    "dhcp-ddns": {\n'
            printf '        "enable-updates": true,\n'
            printf '        "server-ip": "127.0.0.1",\n'
            printf '        "server-port": %s\n' "$KEA_D2_PORT"
            printf '    },\n'
            printf '    "ddns-send-updates": true,\n'
            printf '    "ddns-override-client-update": true,\n'
            printf '    "ddns-replace-client-name": "when-not-present",\n'
            printf '    "ddns-qualifying-suffix": "%s",\n\n' "$(json_esc "${VAL[domain]}")"
        else
            printf '    "dhcp-ddns": { "enable-updates": false },\n\n'
        fi

        printf '    "subnet4": [\n'
        printf '        {\n'
        printf '            "id": 1,\n'
        printf '            "subnet": "%s/%s",\n' "${VAL[dhcp_subnet]}" "$pfx"
        printf '            "pools": [ %s ],\n' "$pool_line"
        if (( ${#KEA_OPTS[@]} > 0 )); then
            printf '            "option-data": [\n'
            json_list '                ' "${KEA_OPTS[@]}"
            printf '            ],\n'
        fi
        if [[ -n ${VAL[dhcp_next]} ]]; then
            printf '            "next-server": "%s",\n' "${VAL[dhcp_next]}"
            [[ -n ${VAL[dhcp_file]} ]] && \
                printf '            "boot-file-name": "%s",\n' "$(json_esc "${VAL[dhcp_file]}")"
        fi
        printf '            "reservations": [\n'
        if (( ${#KEA_RES[@]} > 0 )); then
            json_list '                ' "${KEA_RES[@]}"
        fi
        printf '            ]\n'
        printf '        }\n'
        printf '    ],\n\n'

        printf '    "loggers": [\n'
        printf '        {\n'
        printf '            "name": "kea-dhcp4",\n'
        printf '            "%s": [\n' "$okey"
        printf '                {\n'
        printf '                    "output": "%s/kea-dhcp4.log",\n' "$KEA_LOGDIR"
        printf '                    "maxsize": 10485760,\n'
        printf '                    "maxver": 5\n'
        printf '                }\n'
        printf '            ],\n'
        printf '            "severity": "INFO"\n'
        printf '        }\n'
        printf '    ]\n'
        printf '}\n}\n'
        printf '// %s\n' "$GEN_END"
    } >"$tmp" || { rm -f "$tmp" 2>/dev/null; report_path "$KEA_CONF"; return 1; }

    # Le fichier ne contient aucun secret, mais il doit rester lisible par
    # _kea, sous lequel tourne kea-dhcp4.
    publish_file "$tmp" "$KEA_CONF" 644 || { report_path "$KEA_CONF"; return 1; }
    return 0
}

# Serveur de mise a jour dynamique (kea-dhcp-ddns). Il ne sert que si DDNS est
# demande : sinon le fichier n'est pas touche.
do_kea_ddns_conf() {
    [[ ${VAL[ddns_enable]} == oui ]] || return 0
    local secret algo okey
    secret=$(sed -n 's/.*secret[[:space:]]*"\([^"]*\)".*/\1/p' "$DDNS_KEY_FILE" 2>/dev/null | head -n1)
    if [[ -z $secret ]]; then
        printf 'Secret introuvable dans %s\n' "$DDNS_KEY_FILE"
        return 1
    fi
    # BIND ecrit "hmac-sha256", Kea attend "HMAC-SHA256"
    algo=${VAL[ddns_algo]^^}
    okey=$(kea_output_key)

    local -a fwd=() rev=()
    if [[ ${VAL[dns_forward]} == oui ]]; then
        fwd+=("{ \"name\": \"${VAL[domain]}.\", \"key-name\": \"${VAL[ddns_key]}\", \"dns-servers\": [ { \"ip-address\": \"127.0.0.1\" } ] }")
    fi
    if [[ ${VAL[dns_reverse]} == oui && -n ${VAL[rev_zone]} ]]; then
        rev+=("{ \"name\": \"${VAL[rev_zone]}.\", \"key-name\": \"${VAL[ddns_key]}\", \"dns-servers\": [ { \"ip-address\": \"127.0.0.1\" } ] }")
    fi

    ensure_dir "$KEA_DIR" || return 1
    local tmp; tmp=$(tmp_for "$KEA_D2_CONF")
    {
        printf '// %s\n' "${GEN_MARK#\# }"
        printf '// %s\n' "$(date '+%F %T')"
        printf '{\n"DhcpDdns": {\n'
        printf '    "ip-address": "127.0.0.1",\n'
        printf '    "port": %s,\n\n' "$KEA_D2_PORT"
        printf '    "tsig-keys": [\n'
        printf '        {\n'
        printf '            "name": "%s",\n' "$(json_esc "${VAL[ddns_key]}")"
        printf '            "algorithm": "%s",\n' "$algo"
        printf '            "secret": "%s"\n' "$(json_esc "$secret")"
        printf '        }\n'
        printf '    ],\n\n'
        printf '    "forward-ddns": {\n'
        printf '        "ddns-domains": [\n'
        (( ${#fwd[@]} > 0 )) && json_list '            ' "${fwd[@]}"
        printf '        ]\n'
        printf '    },\n'
        printf '    "reverse-ddns": {\n'
        printf '        "ddns-domains": [\n'
        (( ${#rev[@]} > 0 )) && json_list '            ' "${rev[@]}"
        printf '        ]\n'
        printf '    },\n\n'
        printf '    "loggers": [\n'
        printf '        {\n'
        printf '            "name": "kea-dhcp-ddns",\n'
        printf '            "%s": [\n' "$okey"
        printf '                { "output": "%s/kea-ddns.log", "maxsize": 10485760, "maxver": 5 }\n' "$KEA_LOGDIR"
        printf '            ],\n'
        printf '            "severity": "INFO"\n'
        printf '        }\n'
        printf '    ]\n'
        printf '}\n}\n'
        printf '// %s\n' "$GEN_END"
    } >"$tmp" || { rm -f "$tmp" 2>/dev/null; report_path "$KEA_D2_CONF"; return 1; }

    # Ce fichier porte le secret TSIG : lisible par _kea et par personne
    # d'autre. Sans le groupe _kea, on se rabat sur root seul.
    local d2mode=600 d2own=""
    if group_exists _kea; then d2mode=640; d2own="root:_kea"; fi
    publish_file "$tmp" "$KEA_D2_CONF" "$d2mode" "$d2own" || \
        { report_path "$KEA_D2_CONF"; return 1; }
    return 0
}

# kea_check_one <binaire> <fichier> : controle de syntaxe explique.
#
# "Unable to open file" ne dit ni si le fichier manque, ni s'il est vide, ni
# s'il est illisible : on regarde donc l'etat reel du chemin avant d'appeler
# Kea, et on recopie sa sortie complete dans le journal de l'etape.
kea_check_one() {
    local bin=$1 conf=$2 out rc
    if ! command -v "$bin" >/dev/null 2>&1; then
        printf "%s est introuvable : le paquet Kea n'est pas installe\n" "$bin"
        return 1
    fi
    if ! file_ready "$conf"; then
        report_path "$conf"
        return 1
    fi
    out=$("$bin" -t "$conf" 2>&1); rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$out"
        # Seul un des deux noms du bloc de journalisation passe selon la
        # version. Si c'est le seul reproche, on echange et on recommence :
        # une detection de version un peu vieille ne bloque plus rien.
        if [[ $out == *output-options* ]]; then
            sed -i 's/"output-options"/"output_options"/' "$conf" 2>/dev/null
        elif [[ $out == *output_options* ]]; then
            sed -i 's/"output_options"/"output-options"/' "$conf" 2>/dev/null
        else
            return 1
        fi
        printf 'Nouvel essai avec l autre nom de bloc de journalisation\n'
        out=$("$bin" -t "$conf" 2>&1); rc=$?
        (( rc == 0 )) || printf '%s\n' "$out"
    fi
    return $rc
}

do_check_dhcp() {
    kea_check_one kea-dhcp4 "$KEA_CONF" || return 1
    if [[ ${VAL[ddns_enable]} == oui ]] && command -v kea-dhcp-ddns >/dev/null 2>&1; then
        kea_check_one kea-dhcp-ddns "$KEA_D2_CONF" || return 1
    fi
    return 0
}

#==============================================================================
#  21. TACHES : SYSTEME
#==============================================================================

do_resolv() {
    [[ ${VAL[set_resolv]} == oui ]] || return 0
    # systemd-resolved occupe le port 53 : il faut le desactiver avant BIND
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl disable --now systemd-resolved 2>/dev/null
    fi
    [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
    {
        printf '# %s\n' "${GEN_MARK#\# }"
        printf 'nameserver 127.0.0.1\n'
        printf 'search %s\n' "${VAL[domain]}"
        printf 'domain %s\n' "${VAL[domain]}"
    } >/etc/resolv.conf || return 1
    return 0
}

# Ports a ouvrir selon ce qui est active.
wanted_ports() {
    local p=""
    [[ ${VAL[dns_enable]} == oui ]] && p="53/tcp 53/udp"
    # 67/udp seulement : 68 est le port du client, le serveur n'y ecoute pas
    [[ ${VAL[dhcp_enable]} == oui ]] && p="$p 67/udp"
    printf '%s' "$p"
}

do_firewall() {
    [[ ${VAL[firewall]} == oui ]] || return 0
    local ports; ports=$(wanted_ports)
    [[ -z $ports ]] && return 0
    local p
    if command -v ufw >/dev/null 2>&1; then
        for p in $ports; do
            ufw allow "$p" >/dev/null 2>&1 && printf 'ufw allow %s\n' "$p"
        done
        return 0
    fi
    if command -v nft >/dev/null 2>&1; then
        printf 'nftables detecte : aucune regle ajoutee automatiquement\n'
        return 0
    fi
    printf 'Aucun pare-feu gere : rien a faire\n'
    return 0
}

do_close_firewall() {
    local ports=$1 p
    command -v ufw >/dev/null 2>&1 || { printf 'ufw absent\n'; return 0; }
    for p in $ports; do
        ufw delete allow "$p" >/dev/null 2>&1 && printf 'ufw delete allow %s\n' "$p"
    done
    return 0
}

# Applique l'etat voulu (actif / inactif, demarrage automatique ou non).
do_services() {
    local rc=0
    if [[ ${VAL[dns_enable]} == oui ]]; then
        if [[ ${VAL[boot_start]} == oui ]]; then
            systemctl enable "$BIND_UNIT" 2>&1 || rc=1
        else
            systemctl disable "$BIND_UNIT" 2>&1
        fi
        systemctl restart "$BIND_UNIT" 2>&1 || rc=1
    else
        systemctl disable --now "$BIND_UNIT" 2>&1
    fi

    if [[ ${VAL[dhcp_enable]} == oui ]]; then
        if [[ ${VAL[boot_start]} == oui ]]; then
            systemctl enable "$DHCP_UNIT" 2>&1 || rc=1
        else
            systemctl disable "$DHCP_UNIT" 2>&1
        fi
        systemctl restart "$DHCP_UNIT" 2>&1 || rc=1
    else
        systemctl disable --now "$DHCP_UNIT" 2>&1
    fi

    # kea-dhcp-ddns n'a de sens qu'avec le serveur DHCP et la mise a jour
    # dynamique : dans tous les autres cas on l'arrete.
    if [[ ${VAL[dhcp_enable]} == oui && ${VAL[ddns_enable]} == oui ]]; then
        if [[ ${VAL[boot_start]} == oui ]]; then
            systemctl enable "$D2_UNIT" 2>&1 || rc=1
        else
            systemctl disable "$D2_UNIT" 2>&1
        fi
        systemctl restart "$D2_UNIT" 2>&1 || rc=1
    else
        systemctl disable --now "$D2_UNIT" 2>&1
    fi
    return $rc
}

do_save_config() {
    save_config
}

#==============================================================================
#  22. VALIDATION D'ENSEMBLE
#==============================================================================

# -> 0 si la configuration est applicable, sinon FERR / FKEY
validate_form() {
    FERR=""; FKEY=""
    local i kind

    if [[ ${VAL[dns_enable]} != oui && ${VAL[dhcp_enable]} != oui ]]; then
        FERR="$L_ERR_NOSVC"; FKEY="dns_enable"; return 1
    fi

    local -a common=(server_ip netmask domain)
    local k
    for k in "${common[@]}"; do
        i=$(field_index "$k"); kind=$(field_check_kind "$i")
        if ! validate_value "$kind" "${VAL[$k]}"; then
            FERR="${FLD_LABEL[i]} : $VERR"; FKEY=$k; return 1
        fi
    done

    if [[ ${VAL[dns_enable]} == oui ]]; then
        local -a dns=(ns_name admin_mail dns_allow_query dns_allow_xfer ttl refresh retry expire negttl)
        [[ ${VAL[dns_reverse]} == oui ]] && dns+=(rev_zone)
        for k in "${dns[@]}"; do
            i=$(field_index "$k"); kind=$(field_check_kind "$i")
            if ! validate_value "$kind" "${VAL[$k]}"; then
                FERR="${FLD_LABEL[i]} : $VERR"; FKEY=$k; return 1
            fi
        done
        if [[ ${VAL[dns_forward]} != oui && ${VAL[dns_reverse]} != oui ]]; then
            FERR="$L_ERR_NOZONE"; FKEY="dns_forward"; return 1
        fi
        if [[ ${VAL[dns_forward_only]} == oui && -z ${VAL[dns_forwarders]} ]]; then
            FERR="$L_ERR_NOFWD"; FKEY="dns_forwarders"; return 1
        fi
    fi

    if [[ ${VAL[dhcp_enable]} == oui ]]; then
        local -a dh=(dhcp_subnet dhcp_mask range_start range_end dhcp_dns dhcp_domain dhcp_lease dhcp_maxlease)
        for k in "${dh[@]}"; do
            i=$(field_index "$k"); kind=$(field_check_kind "$i")
            if ! validate_value "$kind" "${VAL[$k]}"; then
                FERR="${FLD_LABEL[i]} : $VERR"; FKEY=$k; return 1
            fi
        done
        if [[ -z ${VAL[dhcp_iface]} ]]; then
            FERR="$L_ERR_NOIFACE"; FKEY="dhcp_iface"; return 1
        fi
        local net
        net=$(network_of "${VAL[dhcp_subnet]}" "${VAL[dhcp_mask]}")
        if [[ $net != "${VAL[dhcp_subnet]}" ]]; then
            FERR="$(printf "$L_ERR_SUBNET" "$net")"; FKEY="dhcp_subnet"; return 1
        fi
        if ! ip_in_network "${VAL[range_start]}" "${VAL[dhcp_subnet]}" "${VAL[dhcp_mask]}"; then
            FERR="$L_ERR_RANGE_OUT"; FKEY="range_start"; return 1
        fi
        if ! ip_in_network "${VAL[range_end]}" "${VAL[dhcp_subnet]}" "${VAL[dhcp_mask]}"; then
            FERR="$L_ERR_RANGE_OUT"; FKEY="range_end"; return 1
        fi
        if (( $(ip_to_int "${VAL[range_start]}") > $(ip_to_int "${VAL[range_end]}") )); then
            FERR="$L_ERR_RANGE_ORDER"; FKEY="range_start"; return 1
        fi
        if ip_in_network "${VAL[server_ip]}" "${VAL[dhcp_subnet]}" "${VAL[dhcp_mask]}"; then
            local s e a
            s=$(ip_to_int "${VAL[range_start]}"); e=$(ip_to_int "${VAL[range_end]}")
            a=$(ip_to_int "${VAL[server_ip]}")
            if (( a >= s && a <= e )); then
                FERR="$L_ERR_RANGE_SELF"; FKEY="range_start"; return 1
            fi
        fi
        if (( ${VAL[dhcp_lease]} > ${VAL[dhcp_maxlease]} )); then
            FERR="$L_ERR_LEASE"; FKEY="dhcp_maxlease"; return 1
        fi
        parse_list "${VAL[reservations]}"
        local r name mac ip
        for r in "${LIST_ITEMS[@]}"; do
            IFS='|' read -r name mac ip <<<"$r"
            if ! valid_mac "$mac" || ! valid_ip "$ip"; then
                FERR="$(printf "$L_ERR_RESERV" "$name")"; FKEY="reservations"; return 1
            fi
        done
    fi
    return 0
}

#==============================================================================
#  23. TRAITEMENTS COMPLETS
#==============================================================================

# Installation des paquets manquants.
job_install() {
    local need_dns=0 need_dhcp=0
    [[ ${VAL[dns_enable]} == oui ]] && ! pkg_installed bind9 && need_dns=1
    [[ ${VAL[dhcp_enable]} == oui ]] && ! pkg_installed kea-dhcp4-server && need_dhcp=1
    [[ ${VAL[dhcp_enable]} == oui && ${VAL[ddns_enable]} == oui ]] && \
        ! pkg_installed kea-dhcp-ddns-server && need_dhcp=1
    if (( need_dns == 0 && need_dhcp == 0 )); then
        return 2      # rien a faire
    fi
    if (( need_dhcp )) && ! pkg_known kea-dhcp4-server; then
        modal_message "$L_DHCP_MISSING_T" "$L_DHCP_MISSING_B" "$C_ERR"
        return 1
    fi

    log_start "$L_JOB_INSTALL"
    anim_begin install

    APT_LOCK_T0=$SECONDS
    step_run "$L_S_APT_LOCK" 0 5 probe_apt_lock do_wait_apt_lock

    step_run "$L_S_APT_UPDATE" 5 20 probe_apt_update do_apt_update \
        || { die_step "$L_E_APT_UPDATE"; return 1; }

    if (( need_dns )); then
        step_run "$L_S_APT_DNS" 20 60 probe_apt do_install_dns \
            || { die_step "$L_E_APT_DNS"; return 1; }
    else
        step_skip "$L_S_APT_DNS_SKIP" 60
    fi

    if (( need_dhcp )); then
        step_run "$L_S_APT_DHCP" 60 95 probe_apt do_install_dhcp \
            || { die_step "$L_E_APT_DHCP"; return 1; }
    else
        step_skip "$L_S_APT_DHCP_SKIP" 95
    fi

    detect_units
    anim_done "$L_S_DONE"
    return 0
}

# Application complete de la configuration.
job_apply() {
    log_start "$L_JOB_APPLY"
    anim_begin apply

    if [[ ${VAL[backup]} == oui ]]; then
        step_run "$L_S_BACKUP" 0 8 - do_backup \
            || { die_step "$L_E_BACKUP"; return 1; }
    else
        step_skip "$L_S_BACKUP_SKIP" 8
    fi

    step_run "$L_S_SAVECONF" 8 12 - do_save_config \
        || { die_step "$L_E_SAVECONF"; return 1; }

    if [[ ${VAL[dns_enable]} == oui ]]; then
        step_run "$L_S_DDNSKEY" 12 16 - do_ddns_key \
            || { die_step "$L_E_DDNSKEY"; return 1; }
        step_run "$L_S_BIND_OPT" 16 24 - do_bind_options \
            || { die_step "$L_E_BIND_OPT"; return 1; }
        step_run "$L_S_BIND_LOCAL" 24 32 - do_bind_local \
            || { die_step "$L_E_BIND_LOCAL"; return 1; }
        step_run "$L_S_ZONES" 32 44 - do_zone_files \
            || { die_step "$L_E_ZONES"; return 1; }
        step_run "$L_S_CHECK_DNS" 44 52 - do_check_bind \
            || { die_step "$L_E_CHECK_DNS"; return 1; }
    else
        step_skip "$L_S_DNS_SKIP" 52
    fi

    if [[ ${VAL[dhcp_enable]} == oui ]]; then
        step_run "$L_S_DHCP_CONF" 52 62 - do_kea_conf \
            || { die_step "$L_E_DHCP_CONF"; return 1; }
        step_run "$L_S_DHCP_DEF" 62 68 - do_kea_ddns_conf \
            || { die_step "$L_E_DHCP_DEF"; return 1; }
        step_run "$L_S_CHECK_DHCP" 68 76 - do_check_dhcp \
            || { die_step "$L_E_CHECK_DHCP"; return 1; }
    else
        step_skip "$L_S_DHCP_SKIP" 76
    fi

    step_run "$L_S_RESOLV" 76 82 - do_resolv \
        || { die_step "$L_E_RESOLV"; return 1; }

    step_run "$L_S_FIREWALL" 82 88 - do_firewall \
        || { die_step "$L_E_FIREWALL"; return 1; }

    if [[ ${VAL[restart]} == oui ]]; then
        step_run "$L_S_SERVICES" 88 96 - do_services \
            || { die_step "$L_E_SERVICES"; return 1; }
    else
        step_skip "$L_S_SERVICES_SKIP" 96
    fi

    if [[ ${VAL[uninstaller]} == oui ]]; then
        [[ -w . ]] || UNINSTALL_PATH="/root/uninstall-dns-dhcp.sh"
        step_run "$L_S_UNINST" 96 100 - do_uninstaller \
            || { die_step "$L_E_UNINST"; return 1; }
    fi

    anim_done "$L_S_DONE"
    DIRTY=0
    return 0
}

# Suppression complete.
job_remove() {
    local purge=$1     # 1 = supprimer aussi les paquets
    log_start "$L_JOB_REMOVE"
    anim_begin remove

    step_run "$L_S_R_STOP" 0 15 - do_rm_stop \
        || { die_step "$L_E_R_STOP"; return 1; }

    step_run "$L_S_R_FW" 15 25 - do_rm_firewall

    step_run "$L_S_R_FILES" 25 45 - do_rm_files \
        || { die_step "$L_E_R_FILES"; return 1; }

    if (( purge )); then
        step_run "$L_S_R_PKG" 45 90 probe_apt do_rm_packages \
            || { die_step "$L_E_R_PKG"; return 1; }
    else
        step_skip "$L_S_R_PKG_SKIP" 90
    fi

    step_run "$L_S_R_CONF" 90 100 - do_rm_conf

    anim_done "$L_S_DONE"
    return 0
}

do_rm_stop() {
    systemctl disable --now "$BIND_UNIT" 2>&1
    systemctl disable --now "$DHCP_UNIT" 2>&1
    systemctl disable --now "$D2_UNIT" 2>&1
    return 0
}

do_rm_firewall() {
    do_close_firewall "53/tcp 53/udp 67/udp 68/udp"
}

do_rm_files() {
    rm -f "$BIND_OPTIONS" "$BIND_LOCAL" "$DDNS_KEY_FILE" 2>/dev/null
    rm -rf "$BIND_ZONE_DIR" 2>/dev/null
    rm -f "$KEA_CONF" "$KEA_D2_CONF" 2>/dev/null
    printf 'Fichiers de configuration generes supprimes\n'
    return 0
}

do_rm_packages() {
    : >"$APT_STATUS"
    apt-get -o APT::Status-Fd=3 -y purge bind9 bind9-utils bind9-dnsutils \
            bind9-doc dnsutils kea-dhcp4-server kea-dhcp-ddns-server \
            3>"$APT_STATUS" 2>&1
    apt-get -y autoremove --purge 2>&1
    return 0
}

do_rm_conf() {
    rm -f "$CONF_FILE" 2>/dev/null
    printf 'Etat enregistre supprime (les sauvegardes de %s sont conservees)\n' "$BACKUP_DIR"
    return 0
}

#==============================================================================
#  24. SCRIPT DE DESINSTALLATION AUTONOME
#
#  Il fige les valeurs du moment pour rester utilisable meme si ce script
#  disparait. Volontairement en mode texte : c'est un filet de securite, pas
#  une seconde interface.
#==============================================================================

do_uninstaller() {
    local out="${UNINSTALL_PATH:-./uninstall-dns-dhcp.sh}"
    local gen_date; gen_date=$(date '+%F %T')
    {
        cat <<CONF
#!/bin/bash
#==============================================================================
#  Desinstallation de BIND9 et de Kea DHCP4
#  Genere le $gen_date par manage-dns-dhcp.sh v$SCRIPT_VERSION
#
#  Usage : sudo $out [--yes] [--keep-packages] [--help]
#==============================================================================

BIND_UNIT='$BIND_UNIT'
DHCP_UNIT='$DHCP_UNIT'
D2_UNIT='$D2_UNIT'
BIND_OPTIONS='$BIND_OPTIONS'
BIND_LOCAL='$BIND_LOCAL'
BIND_ZONE_DIR='$BIND_ZONE_DIR'
BIND_LOGDIR='$BIND_LOGDIR'
DDNS_KEY_FILE='$DDNS_KEY_FILE'
KEA_CONF='$KEA_CONF'
KEA_D2_CONF='$KEA_D2_CONF'
KEA_LOGDIR='$KEA_LOGDIR'
CONF_DIR='$CONF_DIR'
BACKUP_DIR='$BACKUP_DIR'
# superset volontaire : on ferme aussi 68/udp, qu'une version anterieure du
# script pouvait avoir ouvert
PORTS='53/tcp 53/udp 67/udp 68/udp'
CONF
        cat <<'UNINSTALLER_EOF'
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/usr/sbin:/sbin"

YES=0
KEEP=0
for a in "$@"; do
    case $a in
        --yes|-y)        YES=1 ;;
        --keep-packages) KEEP=1 ;;
        --help|-h)
            sed -n '2,10p' "$0"
            exit 0 ;;
        *) printf 'Option inconnue : %s\n' "$a" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    printf 'Ce script doit etre execute avec sudo ou en tant que root.\n' >&2
    exit 1
fi

printf 'Suppression de BIND9 et de Kea DHCP4\n'
printf '  services      : %s, %s, %s\n' "$BIND_UNIT" "$DHCP_UNIT" "$D2_UNIT"
printf '  fichiers      : %s, %s, %s\n' "$BIND_OPTIONS" "$BIND_LOCAL" "$KEA_CONF"
printf '  zones         : %s\n' "$BIND_ZONE_DIR"
if (( KEEP )); then
    printf '  paquets       : conserves\n'
else
    printf '  paquets       : bind9 et kea-dhcp4-server seront purges\n'
fi
printf '  sauvegardes   : %s (conservees)\n' "$BACKUP_DIR"

if (( ! YES )); then
    read -r -p 'Confirmer la suppression ? [o/N] ' rep
    case $rep in
        o|O|y|Y) ;;
        *) printf 'Abandon.\n'; exit 0 ;;
    esac
fi

step() { printf '\n== %s\n' "$1"; }

step 'Arret des services'
systemctl disable --now "$BIND_UNIT" 2>/dev/null
systemctl disable --now "$DHCP_UNIT" 2>/dev/null
systemctl disable --now "$D2_UNIT" 2>/dev/null

step 'Fermeture des ports'
if command -v ufw >/dev/null 2>&1; then
    for p in $PORTS; do ufw delete allow "$p" >/dev/null 2>&1; done
fi

step 'Suppression des fichiers generes'
rm -f "$BIND_OPTIONS" "$BIND_LOCAL" "$DDNS_KEY_FILE"
rm -rf "$BIND_ZONE_DIR"
rm -f "$KEA_CONF" "$KEA_D2_CONF"
rm -rf "$CONF_DIR"

if (( ! KEEP )); then
    step 'Purge des paquets'
    apt-get -y purge bind9 bind9-utils bind9-dnsutils bind9-doc dnsutils \
        kea-dhcp4-server kea-dhcp-ddns-server 2>/dev/null
    apt-get -y autoremove --purge 2>/dev/null
    rm -rf "$BIND_LOGDIR" "$KEA_LOGDIR"
fi

step 'Termine'
printf 'BIND9 et Kea DHCP4 ont ete retires de cette machine.\n'
printf 'Les sauvegardes restent disponibles dans %s\n' "$BACKUP_DIR"
UNINSTALLER_EOF
    } >"$out" || return 1
    chmod 755 "$out" || return 1
    printf 'Script de desinstallation ecrit : %s\n' "$out"
    return 0
}

#==============================================================================
#  25. GESTION DES ENREGISTREMENTS DNS
#==============================================================================

REC_TYPES="A;AAAA;CNAME;MX;TXT;SRV;NS"

# Controle la valeur d'un enregistrement selon son type.
record_value_ok() {
    local type=$1 v=$2
    RVERR=""
    case $type in
        A)     valid_ip "$v" || RVERR="$L_ERR_IP" ;;
        AAAA)  [[ $v =~ ^[0-9a-fA-F:]+$ ]] || RVERR="$L_ERR_IP6" ;;
        CNAME|NS)
            [[ $v =~ ^[a-zA-Z0-9._-]+$ ]] || RVERR="$L_ERR_TARGET" ;;
        MX)    [[ $v =~ ^[0-9]+[[:space:]]+[a-zA-Z0-9._-]+$ ]] || RVERR="$L_ERR_MX" ;;
        SRV)   [[ $v =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[a-zA-Z0-9._-]+$ ]] || RVERR="$L_ERR_SRV" ;;
        TXT)   [[ -n $v && $v != *'"'* ]] || RVERR="$L_ERR_TXT" ;;
    esac
    [[ -z $RVERR ]]
}

# Saisie guidee d'un enregistrement -> REC_NEW ("nom|type|valeur")
record_form() {
    local cur=$1 name="" type="A" value=""
    [[ -n $cur ]] && IFS='|' read -r name type value <<<"$cur"

    while :; do
        modal_edit "$L_REC_T" "$L_REC_NAME" "$name" 0 "$L_REC_NAME_H" || return 1
        name=$EDITED
        if [[ $name != "@" ]] && ! valid_host "$name"; then
            modal_message "$L_INVALID_T" "$L_ERR_HOST" "$C_ERR"; continue
        fi
        break
    done

    local IFS=';'
    local -a types=($REC_TYPES)
    IFS=$' \t\n'
    LM_LABEL=("${types[@]}"); LM_STATE=(); LM_SEL=0
    local j
    for (( j = 0; j < ${#types[@]}; j++ )); do
        [[ ${types[j]} == "$type" ]] && LM_SEL=$j
    done
    LM_ACT=""
    list_menu "$L_REC_TYPE" "$L_MENU_PICK" || return 1
    [[ -n $LM_ACT ]] && { LM_ACT=""; return 1; }
    type=${types[$LM_SEL]}

    while :; do
        modal_edit "$L_REC_T" "$L_REC_VALUE ($type)" "$value" 0 "$(record_hint "$type")" || return 1
        value=$EDITED
        if [[ $value == *'|'* || $value == *';'* ]]; then
            modal_message "$L_INVALID_T" "$L_ERR_SEP" "$C_ERR"; continue
        fi
        if ! record_value_ok "$type" "$value"; then
            modal_message "$L_INVALID_T" "$RVERR" "$C_ERR"; continue
        fi
        break
    done

    REC_NEW="$name|$type|$value"
    return 0
}

record_hint() {
    case $1 in
        A)     printf '%s' "$L_RH_A" ;;
        AAAA)  printf '%s' "$L_RH_AAAA" ;;
        CNAME) printf '%s' "$L_RH_CNAME" ;;
        MX)    printf '%s' "$L_RH_MX" ;;
        TXT)   printf '%s' "$L_RH_TXT" ;;
        SRV)   printf '%s' "$L_RH_SRV" ;;
        NS)    printf '%s' "$L_RH_NS" ;;
    esac
}

records_menu() {
    local name type value e
    while :; do
        parse_list "${VAL[records]}"
        LM_LABEL=(); LM_STATE=()
        for e in "${LIST_ITEMS[@]}"; do
            IFS='|' read -r name type value <<<"$e"
            LM_LABEL+=("$(printf '%-16s %-6s %s' "$name" "$type" "$value")")
            LM_STATE+=("")
        done
        LM_LABEL+=("$L_LIST_ADD")
        LM_STATE+=("ok")
        LM_ACT=""
        list_menu "$L_RECORDS_T" "$L_LIST_HELP" || return 0
        local sel=$LM_SEL act=$LM_ACT
        LM_ACT=""
        local n=${#LIST_ITEMS[@]}

        if [[ $act == add ]] || (( sel == n )); then
            REC_NEW=""
            if record_form ""; then
                LIST_ITEMS+=("$REC_NEW")
                VAL[records]=$(join_list); DIRTY=1
            fi
            continue
        fi
        (( sel < 0 || sel >= n )) && continue

        if [[ $act == del ]]; then
            IFS='|' read -r name type value <<<"${LIST_ITEMS[sel]}"
            if modal_confirm "$L_LIST_DEL_T" "$(printf "$L_LIST_DEL_Q" "$name $type $value")" 1; then
                unset 'LIST_ITEMS[sel]'
                LIST_ITEMS=("${LIST_ITEMS[@]}")
                VAL[records]=$(join_list); DIRTY=1
            fi
            continue
        fi

        REC_NEW=""
        if record_form "${LIST_ITEMS[sel]}"; then
            LIST_ITEMS[sel]=$REC_NEW
            VAL[records]=$(join_list); DIRTY=1
        fi
    done
}

#==============================================================================
#  26. GESTION DES RESERVATIONS DHCP
#==============================================================================

# Saisie guidee d'une reservation -> RES_NEW ("nom|mac|ip")
reserv_form() {
    local cur=$1 name="" mac="" ip=""
    [[ -n $cur ]] && IFS='|' read -r name mac ip <<<"$cur"

    while :; do
        modal_edit "$L_RES_T" "$L_RES_NAME" "$name" 0 "$L_RES_NAME_H" || return 1
        name=$EDITED
        valid_host "$name" && break
        modal_message "$L_INVALID_T" "$L_ERR_HOST" "$C_ERR"
    done
    while :; do
        modal_edit "$L_RES_T" "$L_RES_MAC" "$mac" 0 "$L_RES_MAC_H" || return 1
        mac=${EDITED,,}
        mac=${mac//-/:}
        valid_mac "$mac" && break
        modal_message "$L_INVALID_T" "$L_ERR_MAC" "$C_ERR"
    done
    while :; do
        modal_edit "$L_RES_T" "$L_RES_IP" "$ip" 0 "$L_RES_IP_H" || return 1
        ip=$EDITED
        if ! valid_ip "$ip"; then
            modal_message "$L_INVALID_T" "$L_ERR_IP" "$C_ERR"; continue
        fi
        if [[ ${VAL[dhcp_enable]} == oui ]] && \
           ! ip_in_network "$ip" "${VAL[dhcp_subnet]}" "${VAL[dhcp_mask]}"; then
            modal_message "$L_INVALID_T" "$L_ERR_RES_NET" "$C_ERR"; continue
        fi
        # une adresse reservee prise dans la plage dynamique finit toujours en
        # conflit : Kea DHCP4 refuse de servir deux fois la meme adresse
        if valid_ip "${VAL[range_start]}" && valid_ip "${VAL[range_end]}"; then
            local a s en
            a=$(ip_to_int "$ip"); s=$(ip_to_int "${VAL[range_start]}"); en=$(ip_to_int "${VAL[range_end]}")
            if (( a >= s && a <= en )); then
                modal_confirm "$L_RES_INRANGE_T" "$L_RES_INRANGE_Q" 1 || continue
            fi
        fi
        break
    done

    RES_NEW="$name|$mac|$ip"
    return 0
}

reserv_menu() {
    local name mac ip e
    while :; do
        parse_list "${VAL[reservations]}"
        LM_LABEL=(); LM_STATE=()
        for e in "${LIST_ITEMS[@]}"; do
            IFS='|' read -r name mac ip <<<"$e"
            LM_LABEL+=("$(printf '%-16s %-18s %s' "$name" "$mac" "$ip")")
            LM_STATE+=("")
        done
        LM_LABEL+=("$L_LIST_ADD")
        LM_STATE+=("ok")
        LM_ACT=""
        list_menu "$L_RESERV_T" "$L_LIST_HELP" || return 0
        local sel=$LM_SEL act=$LM_ACT
        LM_ACT=""
        local n=${#LIST_ITEMS[@]}

        if [[ $act == add ]] || (( sel == n )); then
            RES_NEW=""
            if reserv_form ""; then
                LIST_ITEMS+=("$RES_NEW")
                VAL[reservations]=$(join_list); DIRTY=1
            fi
            continue
        fi
        (( sel < 0 || sel >= n )) && continue

        if [[ $act == del ]]; then
            IFS='|' read -r name mac ip <<<"${LIST_ITEMS[sel]}"
            if modal_confirm "$L_LIST_DEL_T" "$(printf "$L_LIST_DEL_Q" "$name $mac $ip")" 1; then
                unset 'LIST_ITEMS[sel]'
                LIST_ITEMS=("${LIST_ITEMS[@]}")
                VAL[reservations]=$(join_list); DIRTY=1
            fi
            continue
        fi

        RES_NEW=""
        if reserv_form "${LIST_ITEMS[sel]}"; then
            LIST_ITEMS[sel]=$RES_NEW
            VAL[reservations]=$(join_list); DIRTY=1
        fi
    done
}

#==============================================================================
#  27. ACTIONS DE GESTION
#==============================================================================

# Execute une commande et montre sa sortie dans une fenetre defilante.
run_cmd_view() {
    local title=$1; shift
    local out rc
    out=$("$@" 2>&1); rc=$?
    log_line "commande: $* (code $rc)"
    [[ -z $out ]] && out="$(printf "$L_CMD_RC" "$rc")"
    text_view "$title" "$out"
    return $rc
}

svc_unit_exists() {
    [[ -n $(systemctl list-unit-files --no-legend "$1.service" 2>/dev/null) ]]
}

# svc_do <unite> <start|stop|restart|reload>
svc_do() {
    local unit=$1 act=$2 out rc
    if ! svc_unit_exists "$unit"; then
        modal_message "$L_SVC_T" "$(printf "$L_SVC_ABSENT" "$unit")" "$C_ERR"
        return 1
    fi
    out=$(systemctl "$act" "$unit" 2>&1); rc=$?
    log_line "systemctl $act $unit -> $rc"
    if (( rc == 0 )); then
        STATUS_MSG=$(printf "$L_SVC_OK" "$unit" "$act"); STATUS_KIND="ok"
    else
        [[ -z $out ]] && out=$(systemctl status "$unit" --no-pager -n 20 2>&1)
        text_view "$L_SVC_FAIL_T" "$out"
        STATUS_MSG=$(printf "$L_SVC_KO" "$unit"); STATUS_KIND="err"
    fi
    collect_state
    return $rc
}

# svc_boot_toggle <unite>
svc_boot_toggle() {
    local unit=$1 out rc act="enable"
    svc_enabled "$unit" && act="disable"
    out=$(systemctl "$act" "$unit" 2>&1); rc=$?
    log_line "systemctl $act $unit -> $rc"
    if (( rc == 0 )); then
        STATUS_MSG=$(printf "$L_BOOT_OK" "$unit" "$act"); STATUS_KIND="ok"
    else
        text_view "$L_SVC_FAIL_T" "$out"
        STATUS_KIND="err"
    fi
    collect_state
}

#---------------------------------------------------------------- baux DHCP
# Le fichier de baux de Kea est un CSV :
#   address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,
#   fqdn_rev,hostname,state,user_context,pool_id
# La colonne expire est un horodatage Unix, l'etat 0 designe un bail actif.
# Une adresse peut apparaitre plusieurs fois : seule la derniere ligne compte.
#
# La mise en forme de la date est faite par date(1) et non par awk : strftime()
# est une extension de gawk, absente de mawk, qui est l'awk par defaut de
# Debian. Tout le programme awk refuserait de se compiler.
leases_text() {
    [[ -r $KEA_LEASES ]] || { printf '%s\n' "$L_LEASES_NONE"; return; }
    [[ -n ${1:-} ]] && printf '%s\n' "$1"
    local ip mac host st exp etat fin
    while IFS='|' read -r ip mac host st exp; do
        [[ -n $ip ]] || continue
        [[ -n $host ]] || host="-"
        if [[ $st == 0 ]]; then
            etat=$L_LEASE_ACTIVE
            fin="-"
            [[ $exp =~ ^[0-9]+$ ]] && fin=$(date -d "@$exp" '+%F %H:%M' 2>/dev/null || printf '%s' "$exp")
        else
            etat=$L_LEASE_FREE
            fin="-"
        fi
        printf '%-16s %-18s %-16s %-10s %s\n' "$ip" "$mac" "$host" "$etat" "$fin"
    done < <(awk -F, '
        # "exp" est le nom d une fonction integree : mawk refuse de en faire un
        # tableau. Le champ est donc stocke sous le nom "fin".
        NR > 1 && NF >= 10 {
            ip = $1
            mac[ip] = $2; host[ip] = $9; st[ip] = $10; fin[ip] = $5
            if (!(ip in seen)) { order[++n] = ip; seen[ip] = 1 }
        }
        END {
            for (i = 1; i <= n; i++) {
                ip = order[i]
                printf "%s|%s|%s|%s|%s\n", ip, mac[ip], host[ip], st[ip], fin[ip]
            }
        }
    ' "$KEA_LEASES" 2>/dev/null)
}

show_leases() {
    local head
    head=$(printf '%-16s %-18s %-16s %-10s %s' "IP" "MAC" "HOSTNAME" "ETAT" "FIN")
    local txt; txt=$(leases_text "$head")
    [[ -z $txt ]] && txt="$L_LEASES_NONE"
    text_view "$L_LEASES_T" "$txt"
}

#-------------------------------------------------------------------- journaux
logs_text() {
    local unit=$1 n=${2:-200}
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$unit" -n "$n" --no-pager 2>&1
    else
        tail -n "$n" /var/log/syslog 2>/dev/null | grep -i "$unit"
    fi
}

#---------------------------------------------------------------- test de dig
dig_test() {
    if ! command -v dig >/dev/null 2>&1; then
        modal_message "$L_DIG_T" "$L_DIG_MISSING" "$C_ERR"
        return
    fi
    local target="${VAL[ns_name]}.${VAL[domain]}"
    modal_edit "$L_DIG_T" "$L_DIG_ASK" "$target" 0 "$L_DIG_HINT" || return
    [[ -z $EDITED ]] && return
    run_cmd_view "$L_DIG_T" dig "@127.0.0.1" "$EDITED" +noall +answer +comments
}

#---------------------------------------------------------------- diagnostic
diag_text() {
    local sep="------------------------------------------------------------"
    {
        printf '%s\n' "$L_DIAG_HEAD"
        printf '%s\n' "$sep"
        printf '%-22s : %s\n' "$L_M_HOST" "$MI_HOST"
        printf '%-22s : %s (%s)\n' "$L_M_IP" "$MI_IP" "$MI_IFACE"
        printf '%-22s : %s\n' "$L_M_OS" "$MI_OS"
        printf '%-22s : %s\n' "$L_M_FW" "$MI_FW"
        printf '\n%s\n' "$sep"
        printf '%s\n' "$L_DIAG_SVC"
        printf '%-22s : %s / %s / %s\n' "BIND9" "$MI_DNS_PKG" "$MI_DNS_SVC" "$MI_DNS_BOOT"
        printf '%-22s : %s / %s / %s\n' "Kea DHCP4" "$MI_DHCP_PKG" "$MI_DHCP_SVC" "$MI_DHCP_BOOT"
        if [[ ${VAL[ddns_enable]} == oui ]]; then
            svc_state "$D2_UNIT"
            printf '%-22s : %s / %s\n' "kea-dhcp-ddns" "$MI_D2_PKG" "$SVC_TXT"
        fi
        printf '%-22s : %s / %s\n' "$L_DIAG_UNITS" "$BIND_UNIT" "$DHCP_UNIT"
        printf '%-22s : %s\n' "$L_M_P53" "$MI_P53"
        printf '%-22s : %s\n' "$L_M_P67" "$MI_P67"

        printf '\n%s\n' "$sep"
        printf '%s\n' "$L_DIAG_PORTS"
        ss -lunp 2>/dev/null | grep -E ':(53|67)[[:space:]]' || printf '%s\n' "$L_DIAG_NOPORT"
        ss -ltnp 2>/dev/null | grep -E ':53[[:space:]]'

        if [[ ${VAL[dns_enable]} == oui ]] && command -v named-checkconf >/dev/null 2>&1; then
            printf '\n%s\n' "$sep"
            printf '%s\n' "$L_DIAG_CHECK_DNS"
            named-checkconf 2>&1 && printf '%s\n' "$L_DIAG_OK"
            if [[ -f $BIND_ZONE_DIR/db.${VAL[domain]} ]]; then
                named-checkzone "${VAL[domain]}" "$BIND_ZONE_DIR/db.${VAL[domain]}" 2>&1
            fi
            if [[ -n ${VAL[rev_zone]} && -f $BIND_ZONE_DIR/db.${VAL[rev_zone]} ]]; then
                named-checkzone "${VAL[rev_zone]}" "$BIND_ZONE_DIR/db.${VAL[rev_zone]}" 2>&1
            fi
        fi

        # Un diagnostic muet ne diagnostique rien : quand le DHCP est demande,
        # cette section repond toujours, y compris pour dire ce qui manque.
        if [[ ${VAL[dhcp_enable]} == oui ]]; then
            printf '\n%s\n' "$sep"
            printf '%s\n' "$L_DIAG_CHECK_DHCP"
            if ! command -v kea-dhcp4 >/dev/null 2>&1; then
                printf '%s\n' "$L_CHECK_NO_DHCP"
            elif ! file_ready "$KEA_CONF"; then
                report_path "$KEA_CONF"
            elif kea-dhcp4 -t "$KEA_CONF" 2>&1 | tail -n 12; then
                printf '%s\n' "$L_DIAG_OK"
            fi
        fi

        if command -v dig >/dev/null 2>&1 && [[ ${VAL[dns_enable]} == oui ]]; then
            printf '\n%s\n' "$sep"
            printf '%s\n' "$L_DIAG_RESOLV"
            dig "@127.0.0.1" "${VAL[ns_name]}.${VAL[domain]}" +short +time=2 +tries=1 2>&1 \
                | head -n 5
        fi

        printf '\n%s\n' "$sep"
        printf '%s\n' "$L_DIAG_LEASES"
        printf '%s\n' "$(printf "$L_DIAG_LEASE_N" "$MI_LEASES")"

        printf '\n%s\n' "$sep"
        printf '%s\n' "$L_DIAG_LOGTAIL"
        tail -n 15 "$LOGFILE" 2>/dev/null || printf '%s\n' "$L_FAIL_NONE"
    } 2>&1
}

diag_screen() {
    collect_state
    text_view "$L_DIAG_T" "$(diag_text)"
}

#---------------------------------------------- verification de configuration
check_screen() {
    local out="" res rc
    if [[ ${VAL[dns_enable]} == oui ]]; then
        if command -v named-checkconf >/dev/null 2>&1; then
            res=$(do_check_bind 2>&1); rc=$?
            out+="$L_DIAG_CHECK_DNS"$'\n'
            [[ -n $res ]] && out+="$res"$'\n'
            out+="$(printf "$L_CHECK_RC" "$rc")"$'\n\n'
        else
            out+="$L_CHECK_NO_BIND"$'\n\n'
        fi
    fi
    if [[ ${VAL[dhcp_enable]} == oui ]]; then
        if command -v kea-dhcp4 >/dev/null 2>&1; then
            res=$(do_check_dhcp 2>&1); rc=$?
            out+="$L_DIAG_CHECK_DHCP"$'\n'
            [[ -n $res ]] && out+="$res"$'\n'
            out+="$(printf "$L_CHECK_RC" "$rc")"$'\n'
        else
            out+="$L_CHECK_NO_DHCP"$'\n'
        fi
    fi
    [[ -z $out ]] && out="$L_CHECK_NOTHING"
    text_view "$L_CHECK_T" "$out"
}

#-------------------------------------------------------------- sauvegardes
restore_menu() {
    local -a dirs=()
    local d
    while IFS= read -r d; do [[ -n $d ]] && dirs+=("$d"); done \
        < <(ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | sort -r)
    if (( ${#dirs[@]} == 0 )); then
        modal_message "$L_RESTORE_T" "$L_RESTORE_NONE" "$C_WARN"
        return
    fi
    LM_LABEL=(); LM_STATE=(); LM_SEL=0
    for d in "${dirs[@]}"; do
        LM_LABEL+=("$(basename "$d")")
        LM_STATE+=("")
    done
    LM_ACT=""
    list_menu "$L_RESTORE_T" "$L_MENU_PICK" || { LM_ACT=""; return; }
    [[ -n $LM_ACT ]] && { LM_ACT=""; return; }
    local src=${dirs[$LM_SEL]}
    modal_confirm "$L_RESTORE_T" "$(printf "$L_RESTORE_Q" "$(basename "$src")")" 1 || return

    local f rc=0
    for f in named.conf.options named.conf.local kea-dhcp4.conf \
             kea-dhcp-ddns.conf ddns.key; do
        [[ -f $src/$f ]] || continue
        case $f in
            named.conf.options) cp -a "$src/$f" "$BIND_OPTIONS" || rc=1 ;;
            named.conf.local)   cp -a "$src/$f" "$BIND_LOCAL" || rc=1 ;;
            kea-dhcp4.conf)     cp -a "$src/$f" "$KEA_CONF" || rc=1 ;;
            kea-dhcp-ddns.conf) cp -a "$src/$f" "$KEA_D2_CONF" || rc=1 ;;
            ddns.key)           cp -a "$src/$f" "$DDNS_KEY_FILE" || rc=1 ;;
        esac
    done
    if [[ -d $src/zones ]]; then
        mkdir -p "$BIND_ZONE_DIR"
        cp -a "$src/zones/." "$BIND_ZONE_DIR/" || rc=1
    fi
    if [[ -f $src/config.conf ]]; then
        cp -a "$src/config.conf" "$CONF_FILE" && load_config
    fi
    log_line "restauration depuis $src (code $rc)"
    if (( rc == 0 )); then
        modal_message "$L_RESTORE_T" "$L_RESTORE_OK" "$C_OK"
        DIRTY=0
    else
        modal_message "$L_RESTORE_T" "$L_RESTORE_KO" "$C_ERR"
    fi
    collect_state
}

backup_now() {
    local out rc
    out=$(do_backup 2>&1); rc=$?
    if (( rc == 0 )); then
        modal_message "$L_BACKUP_T" "$out" "$C_OK"
    else
        modal_message "$L_BACKUP_T" "$L_BACKUP_KO" "$C_ERR"
    fi
}

#-------------------------------------------------------------------- pare-feu
# Ouverture et fermeture explicites, independantes du champ "pare-feu" du
# formulaire : ici l'utilisateur demande l'action directement.
fw_open_ports() {
    local ports p
    ports=$(wanted_ports)
    [[ -z $ports ]] && { printf '%s\n' "$L_FW_NOPORT"; return 0; }
    for p in $ports; do ufw allow "$p" 2>&1; done
    return 0
}

fw_close_ports() {
    local p
    for p in 53/tcp 53/udp 67/udp 68/udp; do ufw delete allow "$p" 2>&1; done
    return 0
}

firewall_action() {
    LM_LABEL=("$L_FW_OPEN" "$L_FW_CLOSE" "$L_FW_STATUS")
    LM_STATE=("ok" "warn" "")
    LM_SEL=0; LM_ACT=""
    list_menu "$L_FW_T" "$L_MENU_PICK" || { LM_ACT=""; return; }
    [[ -n $LM_ACT ]] && { LM_ACT=""; return; }
    case $LM_SEL in
        0)
            if ! command -v ufw >/dev/null 2>&1; then
                modal_message "$L_FW_T" "$L_FW_NO_UFW" "$C_WARN"; return
            fi
            run_cmd_view "$L_FW_T" fw_open_ports
            ;;
        1)
            if ! command -v ufw >/dev/null 2>&1; then
                modal_message "$L_FW_T" "$L_FW_NO_UFW" "$C_WARN"; return
            fi
            modal_confirm "$L_FW_T" "$L_FW_CLOSE_Q" 1 || return
            run_cmd_view "$L_FW_T" fw_close_ports
            ;;
        2)
            if command -v ufw >/dev/null 2>&1; then
                run_cmd_view "$L_FW_T" ufw status verbose
            else
                modal_message "$L_FW_T" "$L_FW_NO_UFW" "$C_WARN"
            fi
            ;;
    esac
    collect_state
}

#==============================================================================
#  28. APPLICATION DE LA CONFIGURATION
#==============================================================================

# Resume affiche avant d'appliquer.
apply_summary() {
    local s=""
    s+="$L_SUM_HEAD"$'\n\n'
    if [[ ${VAL[dns_enable]} == oui ]]; then
        s+="$(printf '  %-22s %s' "$L_SUM_DNS" "${VAL[domain]} / ${VAL[ns_name]} -> ${VAL[server_ip]}")"$'\n'
        [[ ${VAL[dns_reverse]} == oui ]] && s+="$(printf '  %-22s %s' "$L_SUM_REV" "${VAL[rev_zone]}")"$'\n'
        s+="$(printf '  %-22s %s' "$L_SUM_FWD" "${VAL[dns_forwarders]:-$L_NONE}")"$'\n'
        s+="$(printf '  %-22s %s' "$L_SUM_RECS" "$(list_count "${VAL[records]}")")"$'\n'
    else
        s+="  $L_SUM_DNS_OFF"$'\n'
    fi
    if [[ ${VAL[dhcp_enable]} == oui ]]; then
        s+="$(printf '  %-22s %s' "$L_SUM_DHCP" "${VAL[dhcp_subnet]}/${VAL[dhcp_mask]} (${VAL[dhcp_iface]})")"$'\n'
        s+="$(printf '  %-22s %s' "$L_SUM_RANGE" "${VAL[range_start]} - ${VAL[range_end]}")"$'\n'
        s+="$(printf '  %-22s %s' "$L_SUM_RES" "$(list_count "${VAL[reservations]}")")"$'\n'
    else
        s+="  $L_SUM_DHCP_OFF"$'\n'
    fi
    s+=$'\n'
    [[ ${VAL[backup]} == oui ]] && s+="  $L_SUM_BACKUP"$'\n'
    [[ ${VAL[restart]} == oui ]] && s+="  $L_SUM_RESTART"$'\n'
    [[ ${VAL[set_resolv]} == oui ]] && s+="  $L_SUM_RESOLV"$'\n'
    s+=$'\n'"$L_SUM_ASK"
    printf '%s' "$s"
}

action_apply() {
    if ! validate_form; then
        modal_message "$L_FORM_KO_T" "$FERR" "$C_ERR"
        select_field_row "$FKEY"
        return 1
    fi
    # Recursion ouverte a tout le monde : c'est la definition d'un resolveur
    # ouvert, utilise pour amplifier les attaques. On le dit avant d'ecrire.
    if [[ ${VAL[dns_enable]} == oui && ${VAL[dns_recursion]} == oui ]] && \
       [[ " ${VAL[dns_allow_query]//;/ } " == *" any "* ]]; then
        modal_confirm "$L_WARN_OPEN_T" "$L_WARN_OPEN_B" 1 || {
            select_field_row dns_allow_query
            return 1
        }
    fi
    modal_confirm "$L_APPLY_T" "$(apply_summary)" || return 1

    job_install
    local rc=$?
    (( rc == 1 )) && { collect_state; return 1; }

    job_apply || { collect_state; return 1; }
    collect_state
    apply_report
    return 0
}

# Ecran de fin : ce qui tourne, ce qui ecoute, ou aller chercher les fichiers.
apply_report() {
    local -a lines=()
    local st

    lines+=("ok|$L_REP_DONE")
    lines+=("|")
    lines+=("|$L_REP_HEAD")
    if [[ ${VAL[dns_enable]} == oui ]]; then
        lines+=("$MI_DNS_SVC_ST|$(printf '  %-20s : %s' "BIND9" "$MI_DNS_SVC")")
        lines+=("|$(printf '  %-20s : %s' "$L_REP_ZONEDIR" "$BIND_ZONE_DIR")")
        lines+=("|$(printf '  %-20s : %s' "$L_REP_DOMAIN" "${VAL[domain]}")")
    else
        lines+=("off|$(printf '  %-20s : %s' "BIND9" "$L_V_DISABLED")")
    fi
    if [[ ${VAL[dhcp_enable]} == oui ]]; then
        lines+=("$MI_DHCP_SVC_ST|$(printf '  %-20s : %s' "Kea DHCP4" "$MI_DHCP_SVC")")
        lines+=("|$(printf '  %-20s : %s' "$L_REP_RANGE" "${VAL[range_start]} - ${VAL[range_end]}")")
    else
        lines+=("off|$(printf '  %-20s : %s' "Kea DHCP4" "$L_V_DISABLED")")
    fi
    lines+=("|")
    lines+=("|$(printf '  %-20s : %s' "$L_REP_CONF" "$CONF_FILE")")
    lines+=("|$(printf '  %-20s : %s' "$L_REP_LOG" "$LOGFILE")")
    [[ ${VAL[uninstaller]} == oui ]] && \
        lines+=("|$(printf '  %-20s : sudo %s' "$L_REP_UNINST" "$UNINSTALL_PATH")")

    if [[ $MI_DNS_SVC_ST == err || $MI_DHCP_SVC_ST == err ]]; then
        lines+=("|")
        lines+=("err|$L_REP_WARN")
    fi

    compute_layout
    BUF=$'\e[2J'
    local w=$(( COLS - 8 ))
    (( w > 76 )) && w=76
    local h=$(( ${#lines[@]} + 4 ))
    (( h > ROWS - 2 )) && h=$(( ROWS - 2 ))
    local y=$(( (ROWS - h) / 2 )) x=$(( (COLS - w) / 2 ))
    (( y < 1 )) && y=1
    (( x < 1 )) && x=1
    draw_box "$y" "$x" "$h" "$w" "$L_REP_T" "$C_FRAME_ON"
    local i kind txt c
    for (( i = 0; i < ${#lines[@]} && i < h - 4; i++ )); do
        kind=${lines[i]%%|*}
        txt=${lines[i]#*|}
        c=$C_VALUE
        [[ -n $kind ]] && c=$(state_color "$kind")
        pad_str "$txt" $(( w - 4 ))
        put $(( y + 1 + i )) $(( x + 2 )) "${c}${PAD}${C_RESET}"
    done
    pad_str "$L_ANY_KEY" $(( w - 4 ))
    put $(( y + h - 2 )) $(( x + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    printf '%s' "$BUF"
    wait_key
}

action_remove() {
    modal_confirm "$L_REMOVE_T" "$L_REMOVE_Q" 1 || return
    local purge=0
    modal_confirm "$L_REMOVE_T" "$L_REMOVE_PURGE_Q" 1 && purge=1
    job_remove "$purge"
    collect_state
    modal_message "$L_REMOVE_T" "$L_REMOVE_DONE" "$C_OK"
}

#==============================================================================
#  29. MENU DES ACTIONS
#==============================================================================

declare -a ACT_KEY

act_add() {
    ACT_KEY+=("$1")
    LM_LABEL+=("$2")
    LM_STATE+=("${3:-}")
}

build_actions() {
    ACT_KEY=(); LM_LABEL=(); LM_STATE=()

    act_add apply   "$L_A_APPLY" "ok"
    act_add install "$L_A_INSTALL"
    act_add check   "$L_A_CHECK"
    act_add diag    "$L_A_DIAG"

    if pkg_installed bind9; then
        if [[ $MI_DNS_SVC_ST == ok ]]; then
            act_add dns_stop "$L_A_DNS_STOP" "warn"
        else
            act_add dns_start "$L_A_DNS_START" "ok"
        fi
        act_add dns_restart "$L_A_DNS_RESTART"
        act_add dns_reload  "$L_A_DNS_RELOAD"
        if svc_enabled "$BIND_UNIT"; then
            act_add dns_boot "$L_A_DNS_BOOT_OFF"
        else
            act_add dns_boot "$L_A_DNS_BOOT_ON"
        fi
    fi

    if pkg_installed kea-dhcp4-server; then
        if [[ $MI_DHCP_SVC_ST == ok ]]; then
            act_add dhcp_stop "$L_A_DHCP_STOP" "warn"
        else
            act_add dhcp_start "$L_A_DHCP_START" "ok"
        fi
        act_add dhcp_restart "$L_A_DHCP_RESTART"
        if svc_enabled "$DHCP_UNIT"; then
            act_add dhcp_boot "$L_A_DHCP_BOOT_OFF"
        else
            act_add dhcp_boot "$L_A_DHCP_BOOT_ON"
        fi
        act_add leases "$L_A_LEASES"
    fi

    act_add records  "$L_A_RECORDS"
    act_add reserv   "$L_A_RESERV"
    act_add dig      "$L_A_DIG"
    act_add logs_dns "$L_A_LOGS_DNS"
    act_add logs_dhcp "$L_A_LOGS_DHCP"
    act_add firewall "$L_A_FIREWALL"
    act_add backup   "$L_A_BACKUP"
    act_add restore  "$L_A_RESTORE"
    act_add derive   "$L_A_DERIVE"
    act_add reset    "$L_A_RESET" "warn"
    act_add remove   "$L_A_REMOVE" "err"
}

actions_menu() {
    while :; do
        build_actions
        LM_SEL=${ACT_LAST:-0}
        LM_ACT=""
        list_menu "$L_ACTIONS_T" "$L_MENU_HELP" || { LM_ACT=""; return; }
        [[ -n $LM_ACT ]] && { LM_ACT=""; continue; }
        ACT_LAST=$LM_SEL
        local key=${ACT_KEY[$LM_SEL]}
        case $key in
            apply)     action_apply; return ;;
            install)
                job_install
                case $? in
                    0) collect_state; modal_message "$L_INSTALL_T" "$L_INSTALL_OK" "$C_OK" ;;
                    2) modal_message "$L_INSTALL_T" "$L_INSTALL_NOTHING" "$C_OK" ;;
                    *) collect_state ;;
                esac
                ;;
            check)      check_screen ;;
            diag)       diag_screen ;;
            dns_start)  svc_do "$BIND_UNIT" start ;;
            dns_stop)   svc_do "$BIND_UNIT" stop ;;
            dns_restart) svc_do "$BIND_UNIT" restart ;;
            dns_reload)
                if command -v rndc >/dev/null 2>&1; then
                    run_cmd_view "$L_A_DNS_RELOAD" rndc reload
                else
                    svc_do "$BIND_UNIT" reload
                fi
                ;;
            dns_boot)   svc_boot_toggle "$BIND_UNIT" ;;
            dhcp_start) svc_do "$DHCP_UNIT" start ;;
            dhcp_stop)  svc_do "$DHCP_UNIT" stop ;;
            dhcp_restart) svc_do "$DHCP_UNIT" restart ;;
            dhcp_boot)  svc_boot_toggle "$DHCP_UNIT" ;;
            leases)     show_leases ;;
            records)    records_menu ;;
            reserv)     reserv_menu ;;
            dig)        dig_test ;;
            logs_dns)   text_view "$L_A_LOGS_DNS" "$(logs_text "$BIND_UNIT")" ;;
            logs_dhcp)  text_view "$L_A_LOGS_DHCP" "$(logs_text "$DHCP_UNIT")" ;;
            firewall)   firewall_action ;;
            backup)     backup_now ;;
            restore)    restore_menu ;;
            derive)
                if modal_confirm "$L_DERIVE_T" "$L_DERIVE_Q"; then
                    derive_network 1
                    DIRTY=1
                    STATUS_MSG="$L_DERIVE_OK"; STATUS_KIND="ok"
                    return
                fi
                ;;
            reset)
                if modal_confirm "$L_RESET_T" "$L_RESET_Q" 1; then
                    reset_form
                    STATUS_MSG="$L_RESET_OK"; STATUS_KIND="ok"
                    return
                fi
                ;;
            remove)     action_remove; return ;;
        esac
    done
}

# Remet toutes les valeurs par defaut sans toucher aux fichiers en place.
reset_form() {
    local i
    SEC_NAME=(); SEC_OPEN=()
    FLD_SEC=(); FLD_KEY=(); FLD_LABEL=(); FLD_TYPE=(); FLD_HINT=(); FLD_COND=(); FLD_OPTS=()
    VAL=()
    build_form
    derive_network 1
    DIRTY=1
    SEL=0; SCROLL=0
}

#==============================================================================
#  30. VERIFICATIONS PREALABLES
#==============================================================================

precheck() {
    if [[ $EUID -ne 0 ]]; then
        printf '%s\n' "Ce script doit etre execute avec sudo ou en tant que root." >&2
        printf '%s\n' "This script must be run with sudo or as root." >&2
        exit 1
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' "Systeme non supporte : apt-get est introuvable (Debian ou Ubuntu attendu)." >&2
        printf '%s\n' "Unsupported system: apt-get not found (Debian or Ubuntu expected)." >&2
        exit 1
    fi
    if ! command -v ip >/dev/null 2>&1; then
        printf '%s\n' "La commande 'ip' est requise (paquet iproute2)." >&2
        printf '%s\n' "The 'ip' command is required (iproute2 package)." >&2
        exit 1
    fi
    touch "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/dns-dhcp-auto.log"
    chmod 600 "$LOGFILE" 2>/dev/null
}

precheck_tui() {
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf '%s\n' "Ce script necessite un terminal interactif (ou une option, voir --help)." >&2
        printf '%s\n' "This script requires an interactive terminal (or an option, see --help)." >&2
        exit 1
    fi
}

#==============================================================================
#  31. MODE LIGNE DE COMMANDE
#==============================================================================

CLI_MODE=0
CLI_ACTION=""
CLI_TARGET="all"

usage() {
    cat <<EOF
DNS-DHCP AUTO v$SCRIPT_VERSION - gestion de BIND9 et d'Kea DHCP4

Usage : sudo $0 [option]

Sans option, le script ouvre son interface de gestion.

  --apply                applique la configuration enregistree, sans interface
  --check                verifie les fichiers de configuration
  --status               affiche l'etat des services et des ports
  --leases               liste les baux DHCP
  --backup               sauvegarde les fichiers de configuration
  --start   <cible>      demarre   dns | dhcp | all
  --stop    <cible>      arrete    dns | dhcp | all
  --restart <cible>      redemarre dns | dhcp | all
  --enable  <cible>      active le demarrage automatique
  --disable <cible>      desactive le demarrage automatique
  --lang <fr|en>         force la langue
  --version              affiche la version
  --help                 affiche cette aide

Fichiers :
  configuration enregistree : $CONF_FILE
  journal                   : $LOGFILE
  sauvegardes               : $BACKUP_DIR
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case $1 in
            --help|-h)    usage; exit 0 ;;
            --version|-V) printf 'dns-dhcp-auto %s\n' "$SCRIPT_VERSION"; exit 0 ;;
            --lang)
                shift
                case ${1:-} in
                    fr|en) DDAUTO_LANG=$1 ;;
                    *) printf 'Langue inconnue : %s\n' "${1:-}" >&2; exit 1 ;;
                esac
                ;;
            --apply|--check|--status|--leases|--backup)
                CLI_MODE=1; CLI_ACTION=${1#--} ;;
            --start|--stop|--restart|--enable|--disable)
                CLI_MODE=1; CLI_ACTION=${1#--}
                shift
                case ${1:-all} in
                    dns|dhcp|all) CLI_TARGET=${1:-all} ;;
                    *) printf 'Cible inconnue : %s (dns, dhcp ou all)\n' "${1:-}" >&2; exit 1 ;;
                esac
                ;;
            *)
                printf 'Option inconnue : %s\n' "$1" >&2
                printf 'Voir %s --help\n' "$0" >&2
                exit 1 ;;
        esac
        shift
    done
}

cli_units() {
    case $CLI_TARGET in
        dns)  printf '%s' "$BIND_UNIT" ;;
        dhcp) printf '%s' "$DHCP_UNIT" ;;
        *)    printf '%s %s' "$BIND_UNIT" "$DHCP_UNIT" ;;
    esac
}

cli_status() {
    collect_state
    printf '%-24s : %s\n' "$L_M_HOST" "$MI_HOST"
    printf '%-24s : %s (%s)\n' "$L_M_IP" "$MI_IP" "$MI_IFACE"
    printf '%-24s : %s / %s / %s\n' "BIND9" "$MI_DNS_PKG" "$MI_DNS_SVC" "$MI_DNS_BOOT"
    printf '%-24s : %s / %s / %s\n' "Kea DHCP4" "$MI_DHCP_PKG" "$MI_DHCP_SVC" "$MI_DHCP_BOOT"
    printf '%-24s : %s / %s\n' "Unites systemd" "$BIND_UNIT" "$DHCP_UNIT"
    printf '%-24s : %s\n' "$L_M_P53" "$MI_P53"
    printf '%-24s : %s\n' "$L_M_P67" "$MI_P67"
    printf '%-24s : %s\n' "$L_M_FW" "$MI_FW"
    printf '%-24s : %s\n' "$L_M_ZONES" "$MI_ZONES / $MI_LEASES"
}

run_cli() {
    local u rc=0
    case $CLI_ACTION in
        status) cli_status ;;
        leases)
            local head
            head=$(printf '%-16s %-18s %-16s %-10s %s' "IP" "MAC" "HOSTNAME" "ETAT" "FIN")
            leases_text "$head"
            ;;
        check)
            # Les deux controles disent maintenant eux-memes ce qui manque,
            # outil comme fichier : plus besoin de les court-circuiter, et un
            # succes se voit au lieu de se deviner.
            if [[ ${VAL[dns_enable]} == oui ]]; then
                printf '%s\n' "$L_DIAG_CHECK_DNS"
                if do_check_bind; then printf '%s\n' "$L_DIAG_OK"; else rc=1; fi
            fi
            if [[ ${VAL[dhcp_enable]} == oui ]]; then
                printf '%s\n' "$L_DIAG_CHECK_DHCP"
                if do_check_dhcp; then printf '%s\n' "$L_DIAG_OK"; else rc=1; fi
            fi
            ;;
        backup)
            do_backup || rc=1
            ;;
        apply)
            if [[ ! -r $CONF_FILE ]]; then
                printf '%s\n' "$L_CLI_NOCONF" >&2
                return 1
            fi
            if ! validate_form; then
                printf '%s\n' "$FERR" >&2
                return 1
            fi
            job_install
            (( $? == 1 )) && return 1
            job_apply || return 1
            printf '%s\n' "$L_CLI_APPLIED"
            ;;
        start|stop|restart)
            for u in $(cli_units); do
                printf '%s %s ... ' "$CLI_ACTION" "$u"
                if systemctl "$CLI_ACTION" "$u" 2>&1; then printf 'ok\n'; else printf 'echec\n'; rc=1; fi
            done
            ;;
        enable|disable)
            for u in $(cli_units); do
                printf '%s %s ... ' "$CLI_ACTION" "$u"
                if systemctl "$CLI_ACTION" "$u" 2>&1; then printf 'ok\n'; else printf 'echec\n'; rc=1; fi
            done
            ;;
    esac
    return $rc
}

#==============================================================================
#  32. BOUCLE PRINCIPALE
#==============================================================================

cleanup() {
    (( CLI_MODE )) || tui_stop
    rm -f "$STEP_LOG" "$APT_STATUS" "$CONF_FILE.tmp" 2>/dev/null
    # Une generation interrompue laisse son fichier de travail a cote de la
    # destination : il n'a rien a faire dans /etc ni dans une sauvegarde.
    rm -f "$BIND_DIR"/*.dnsdhcp-*.tmp "$BIND_ZONE_DIR"/*.dnsdhcp-*.tmp \
          "$KEA_DIR"/*.dnsdhcp-*.tmp 2>/dev/null
}

quit_flow() {
    if (( DIRTY )); then
        case $(confirm3 "$L_QUIT_T" "$L_QUIT_DIRTY") in
            save)
                if save_config; then
                    return 0
                fi
                modal_message "$L_SAVE_T" "$L_SAVE_KO" "$C_ERR"
                return 1
                ;;
            quit)   return 0 ;;
            *)      return 1 ;;
        esac
    fi
    modal_confirm "$L_QUIT_T" "$L_QUIT_ASK" && return 0
    return 1
}

# Trois reponses possibles : enregistrer, quitter sans enregistrer, annuler.
confirm3() {
    local title=$1 text=$2 sel=0
    local -a labels=("$L_C3_SAVE" "$L_C3_QUIT" "$L_C3_CANCEL")
    local -a keys=("save" "quit" "cancel")
    local -a lines
    local w=0 l
    while IFS= read -r l; do lines+=("$l"); (( ${#l} > w )) && w=${#l}; done <<<"$text"
    local blen=0 i
    for (( i = 0; i < 3; i++ )); do blen=$(( blen + ${#labels[i]} + 3 )); done
    (( blen > w )) && w=$blen
    w=$(( w + 6 ))
    (( w > COLS - 4 )) && w=$(( COLS - 4 ))
    local h=$(( ${#lines[@]} + 5 ))
    modal_box "$h" "$w" "$title"
    while :; do
        BUF=""
        for (( i = 0; i < ${#lines[@]}; i++ )); do
            pad_str "${lines[i]}" $(( w - 4 ))
            put $(( MY + 1 + i )) $(( MX + 2 )) "${C_VALUE}${PAD}${C_RESET}"
        done
        local x=$(( MX + w - blen - 3 ))
        for (( i = 0; i < 3; i++ )); do
            if (( sel == i )); then
                put $(( MY + h - 2 )) "$x" "${C_BTN_ON}${C_BOLD}${labels[i]}${C_RESET}"
            else
                put $(( MY + h - 2 )) "$x" "${C_MUTED}${labels[i]}${C_RESET}"
            fi
            x=$(( x + ${#labels[i]} + 3 ))
        done
        printf '%s' "$BUF"
        read_key
        case $KEY in
            LEFT)  (( sel > 0 )) && sel=$(( sel - 1 )) ;;
            RIGHT|TAB) (( sel < 2 )) && sel=$(( sel + 1 )) ;;
            ENTER) printf '%s' "${keys[sel]}"; return 0 ;;
            ESC)   printf 'cancel'; return 0 ;;
        esac
    done
}

main_loop() {
    local n idx dead=0
    while :; do
        build_rows
        build_buttons
        n=${#VR_TYPE[@]}
        (( SEL > n )) && SEL=$n
        (( SEL < 0 )) && SEL=0
        [[ ${VR_TYPE[$SEL]:-} == gap ]] && move_sel 1
        adjust_scroll
        render_main
        read_key
        (( RESIZED )) && { compute_layout; RESIZED=0; STATUS_MSG=""; STATUS_KIND="info"; dead=0; continue; }
        if [[ $KEY == "NONE" ]]; then
            # entree standard perdue (terminal ferme) : on evite la boucle folle
            dead=$(( dead + 1 ))
            (( dead > 200 )) && return 1
            continue
        fi
        dead=0
        STATUS_MSG=""
        STATUS_KIND="info"
        idx=${VR_IDX[$SEL]:--1}
        case $KEY in
            UP|"CHAR:k")   move_sel -1 ;;
            DOWN|"CHAR:j"|TAB) move_sel 1 ;;
            PGUP) SEL=$(( SEL - FORM_ROWS )); (( SEL < 0 )) && SEL=0 ;;
            PGDN) SEL=$(( SEL + FORM_ROWS )); (( SEL > n )) && SEL=$n ;;
            HOME) SEL=0 ;;
            END)  SEL=$n ;;
            LEFT|"CHAR:h")
                if sel_is_button; then
                    move_btn -1
                elif [[ ${VR_TYPE[$SEL]} == sec ]]; then
                    SEC_OPEN[idx]=0
                elif [[ ${FLD_TYPE[$idx]} == bool ]]; then
                    toggle_bool "${FLD_KEY[$idx]}"
                elif [[ ${FLD_TYPE[$idx]} == choice ]]; then
                    cycle_choice "$idx" -1; on_field_changed "${FLD_KEY[$idx]}"
                fi
                ;;
            RIGHT|"CHAR:l")
                if sel_is_button; then
                    move_btn 1
                elif [[ ${VR_TYPE[$SEL]} == sec ]]; then
                    SEC_OPEN[idx]=1
                elif [[ ${FLD_TYPE[$idx]} == bool ]]; then
                    toggle_bool "${FLD_KEY[$idx]}"
                elif [[ ${FLD_TYPE[$idx]} == choice ]]; then
                    cycle_choice "$idx" 1; on_field_changed "${FLD_KEY[$idx]}"
                fi
                ;;
            SPACE)
                if sel_is_button; then
                    activate_button || return 1
                elif [[ ${VR_TYPE[$SEL]} == fld && ${FLD_TYPE[$idx]} == bool ]]; then
                    toggle_bool "${FLD_KEY[$idx]}"
                elif [[ ${VR_TYPE[$SEL]} == sec ]]; then
                    SEC_OPEN[idx]=$(( 1 - SEC_OPEN[idx] ))
                fi
                ;;
            ENTER)
                if sel_is_button; then
                    activate_button || return 1
                elif [[ ${VR_TYPE[$SEL]} == sec ]]; then
                    SEC_OPEN[idx]=$(( 1 - SEC_OPEN[idx] ))
                else
                    edit_field "$idx"
                fi
                ;;
            "CHAR:a"|"CHAR:A") actions_menu ;;
            "CHAR:d"|"CHAR:D") diag_screen ;;
            "CHAR:s"|"CHAR:S")
                if save_config; then
                    DIRTY=0
                    STATUS_MSG="$(printf "$L_SAVE_OK" "$CONF_FILE")"; STATUS_KIND="ok"
                else
                    STATUS_MSG="$L_SAVE_KO"; STATUS_KIND="err"
                fi
                ;;
            "CHAR:t"|"CHAR:T")
                toggle_theme
                if [[ $THEME == light ]]; then
                    STATUS_MSG="$L_ST_THEME_LIGHT"
                else
                    STATUS_MSG="$L_ST_THEME_DARK"
                fi
                STATUS_KIND="ok"
                ;;
            "CHAR:r"|"CHAR:R")
                STATUS_MSG="$L_ST_REFRESHING"
                STATUS_KIND="info"
                render_main
                collect_state
                STATUS_MSG="$L_ST_REFRESHED"
                STATUS_KIND="ok"
                ;;
            "CHAR:q"|"CHAR:Q"|ESC)
                quit_flow && return 0
                ;;
        esac
    done
}

# -> 1 (echec) demande la sortie de la boucle principale
activate_button() {
    case ${BTN_KEY[$BTN_CUR]} in
        apply)   action_apply ;;
        actions) actions_menu ;;
        diag)    diag_screen ;;
        quit)    quit_flow && return 1 ;;
    esac
    return 0
}

main() {
    detect_os_release
    detect_units
    setup_locale
    setup_charset
    setup_colors

    # Les options sont lues avant les controles : --help et --version doivent
    # repondre meme sans droits root et sur une machine mal outillee.
    parse_args "$@"
    precheck

    if (( CLI_MODE )); then
        UILANG=${DDAUTO_LANG:-fr}
        peek_conf_lang && [[ -z ${DDAUTO_LANG:-} ]] && UILANG=$CONF_LANG
        [[ $UILANG == en || $UILANG == fr ]] || UILANG="fr"
        load_strings
        build_form
        load_config
        derive_network 0
        trap cleanup EXIT
        run_cli
        exit $?
    fi

    precheck_tui
    load_tux
    trap cleanup EXIT
    trap 'cleanup; exit 130' INT TERM
    trap on_resize WINCH

    compute_layout
    tui_start

    # la couleur de fond est demandee une fois l'ecran alternatif actif :
    # une eventuelle reponse non consommee reste invisible pour l'utilisateur
    detect_theme
    setup_colors

    if ! select_language; then
        cleanup
        printf '%s\n' "Annule. / Cancelled."
        exit 0
    fi
    load_strings
    build_form
    build_buttons

    local first=1
    load_config && first=0
    derive_network 0
    collect_state

    if term_too_small; then
        render_main
        wait_key
        cleanup
        printf '%s\n' "$L_TOO_SMALL_CLI" >&2
        exit 1
    fi

    # Kea est present dans Debian 12 et 13, mais pas sur toutes les images
    # derivees : mieux vaut le dire tout de suite qu'echouer a l'installation.
    if ! pkg_known kea-dhcp4-server && ! pkg_installed kea-dhcp4-server; then
        modal_message "$L_DHCP_MISSING_T" "$L_DHCP_MISSING_B" "$C_WARN"
    fi

    if (( first )); then
        modal_message "$L_WELCOME_T" "$L_WELCOME_B" "$C_VALUE"
    fi

    main_loop
    cleanup
    trap - EXIT
    printf '%s\n' "$L_BYE"
}

main "$@"
