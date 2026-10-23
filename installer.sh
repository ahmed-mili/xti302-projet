#!/usr/bin/env bash
#
# installer.sh : reconstruit et durcit la VM depuis le snapshot « vierge ».
#
# Usage : sudo ./installer.sh
#
# Le script est idempotent : on peut le relancer sans erreur. Chaque étape est
# une fonction ; les étapes sont appelées dans main, dans un ordre imposé
# (les comptes avant sudo, sudo avant le verrouillage de root).
#
# Codes de sortie : 0 tout va bien, 1 erreur pendant le travail, 2 mauvais usage.
set -euo pipefail

# Dossier du dépôt : le script est à sa racine.
DOSSIER_DEPOT="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Vérifications de départ
# ---------------------------------------------------------------------------

# erreur <message> : affiche un message d'erreur sur la sortie d'erreur.
erreur() {
    echo "erreur : $1" >&2
}

# verifier_usage <nombre d'arguments> : le script n'attend aucun argument.
verifier_usage() {
    if [ "$1" -ne 0 ]; then
        echo "usage : sudo $0" >&2
        exit 2
    fi
}

# verifier_root : l'installation exige root.
verifier_root() {
    if [ "$(id -u)" -ne 0 ]; then
        erreur "ce script doit être lancé en root"
        exit 2
    fi
}

# ---------------------------------------------------------------------------
# Étapes de l'installation
# ---------------------------------------------------------------------------

# installer_paquets : installe les paquets Debian nécessaires (acl pour les
# droits sur /srv, sudo pour l'accès admin). Relancer ne réinstalle rien.
installer_paquets() {
    echo "==> Paquets"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq acl sudo
}

# installer_comptes : crée les groupes, les comptes, les clés et /srv.
installer_comptes() {
    echo "==> Comptes et droits sur /srv"
    "${DOSSIER_DEPOT}/creer_comptes.sh" "${DOSSIER_DEPOT}/comptes.csv"
}

# installer_sudoers : copie les fichiers de config/sudoers.d dans /etc/sudoers.d.
# Chaque fichier est d'abord vérifié avec visudo : un fichier sudoers faux
# bloquerait sudo pour tout le monde.
installer_sudoers() {
    echo "==> sudo"
    local fichier
    local nom

    for fichier in "${DOSSIER_DEPOT}"/config/sudoers.d/*; do
        nom="$(basename "$fichier")"
        if ! visudo -cf "$fichier" >/dev/null; then
            erreur "fichier sudoers invalide : ${fichier}"
            exit 1
        fi
        install -o root -g root -m 0440 "$fichier" "/etc/sudoers.d/${nom}"
        echo "sudoers installé : ${nom}"
    done
}

# retirer_groupe_sudo : vide le groupe sudo de Debian, pour que seul le groupe
# admins donne l'accès administrateur. Garde-fou : on ne retire personne tant
# que ahmed (le compte d'installation) n'est pas dans admins et que 10-admins
# n'est pas installé, sinon on se retrouverait sans sudo.
# id -nG liste tous les groupes de ahmed, principal compris.
retirer_groupe_sudo() {
    echo "==> Groupe sudo"
    local membres_sudo
    local login

    if ! id -nG ahmed | tr ' ' '\n' | grep -qx admins || [ ! -f /etc/sudoers.d/10-admins ]; then
        erreur "ahmed n'est pas dans admins ou 10-admins est absent : on garde le groupe sudo"
        exit 1
    fi

    membres_sudo="$(getent group sudo | cut -d: -f4)"
    for login in ${membres_sudo//,/ }; do
        gpasswd -d "$login" sudo
    done
}

# verrouiller_root : on ne se connecte plus en root (mot de passe verrouillé).
# Les admins passent par sudo. À faire en dernier, une fois sudo vérifié.
verrouiller_root() {
    echo "==> Compte root"
    passwd -l root
}

# securiser_homes : chaque home est fermé aux autres utilisateurs (0750).
securiser_homes() {
    echo "==> Homes"
    local home

    for home in /home/*; do
        chmod 0750 "$home"
    done
}

# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------

# main : appelle les étapes dans l'ordre. Les tâches suivantes ajoutent ici
# leurs propres étapes.
main() {
    installer_paquets
    installer_comptes
    installer_sudoers
    retirer_groupe_sudo
    verrouiller_root
    securiser_homes
    echo "Installation terminée."
}

verifier_usage "$#"
verifier_root
main
