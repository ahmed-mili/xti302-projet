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

# installer_paquets : installe les paquets Debian nécessaires :
#   acl = droits sur /srv ; sudo = accès admin ;
#   fail2ban + python3-systemd = bannir les adresses qui échouent en SSH (il lit
#   le journal systemd) ; nftables = pare-feu ;
#   unattended-upgrades = mises à jour de sécurité automatiques.
# Relancer ne réinstalle rien.
installer_paquets() {
    echo "==> Paquets"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq acl sudo fail2ban python3-systemd nftables unattended-upgrades
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

    # Contrôle final de l'ensemble de la configuration sudo (sudoers + sudoers.d).
    if ! visudo -c >/dev/null; then
        erreur "la configuration sudo est invalide après la copie"
        exit 1
    fi
}

# retirer_groupe_sudo : vide le groupe sudo de Debian, pour que seul le groupe
# admins donne l'accès administrateur. Garde-fou : on ne retire personne tant
# que ahmed (le compte d'installation) n'est pas dans admins, que 10-admins
# n'est pas installé et que ahmed n'a pas de mot de passe utilisable (sudo le
# demande), sinon on se retrouverait sans sudo.
# id -nG liste tous les groupes de ahmed, principal compris.
# passwd -S affiche l'état du mot de passe en 2e colonne : P = utilisable.
retirer_groupe_sudo() {
    echo "==> Groupe sudo"
    local membres_sudo
    local etat_mot_de_passe
    local login

    if ! id -nG ahmed | tr ' ' '\n' | grep -qx admins || [ ! -f /etc/sudoers.d/10-admins ]; then
        erreur "ahmed n'est pas dans admins ou 10-admins est absent : on garde le groupe sudo"
        exit 1
    fi

    etat_mot_de_passe="$(passwd -S ahmed | cut -d' ' -f2)"
    if [ "$etat_mot_de_passe" != "P" ]; then
        erreur "ahmed n'a pas de mot de passe utilisable (état ${etat_mot_de_passe}) : on garde le groupe sudo"
        exit 1
    fi

    # Les membres sont séparés par des virgules : tr les remplace par des espaces.
    membres_sudo="$(getent group sudo | cut -d: -f4)"
    for login in $(echo "$membres_sudo" | tr ',' ' '); do
        gpasswd -d "$login" sudo
    done
}

# verrouiller_root : on ne se connecte plus en root (mot de passe verrouillé).
# Les admins passent par sudo. À faire en dernier, une fois sudo vérifié.
verrouiller_root() {
    echo "==> Compte root"
    passwd -l root
}

# securiser_homes : chaque home est fermé au groupe et aux autres (0700).
securiser_homes() {
    echo "==> Homes"
    local home

    for home in /home/*; do
        # Si /home est vide, le motif /home/* reste tel quel : on saute.
        if [ ! -d "$home" ]; then
            continue
        fi
        chmod 0700 "$home"
    done
}

# installer_ssh : installe la configuration SSH durcie (config/ssh/sshd_config.d).
# Risque : une mauvaise config peut nous enfermer dehors. Précautions :
#   - cette étape passe APRÈS les comptes : le groupe acces_ssh existe et
#     contient les admins quand AllowGroups entre en vigueur ;
#   - on vérifie que ahmed est dans acces_ssh ET qu'il a une clé autorisée
#     (sans clé, PasswordAuthentication no le laisserait dehors) ;
#   - sshd -t valide la config, et ssh n'est redémarré que si elle est bonne ;
#   - si la config est mauvaise, on remet l'ancienne (voir plus bas).
# Les sessions déjà ouvertes survivent au redémarrage de ssh.
installer_ssh() {
    echo "==> SSH"
    local source="${DOSSIER_DEPOT}/config/ssh/sshd_config.d/10-pixelia.conf"
    local cible="/etc/ssh/sshd_config.d/10-pixelia.conf"
    local sauvegarde="/etc/ssh/sshd_config.d/10-pixelia.conf.ancien"
    local cles_ahmed
    cles_ahmed="$(getent passwd ahmed | cut -d: -f6)/.ssh/authorized_keys"

    if ! id -nG ahmed | tr ' ' '
' | grep -qx acces_ssh; then
        erreur "ahmed n'est pas dans acces_ssh : AllowGroups nous enfermerait dehors"
        exit 1
    fi

    # [ -s ] est vrai si le fichier existe et n'est pas vide.
    if [ ! -s "$cles_ahmed" ]; then
        erreur "${cles_ahmed} est absent ou vide : PasswordAuthentication no nous enfermerait dehors"
        exit 1
    fi

    # On garde l'ancienne config (s'il y en a une) avant de la remplacer. Le
    # nom ne finit pas par .conf : sshd ne le lit pas.
    if [ -f "$cible" ]; then
        cp -p "$cible" "$sauvegarde"
    fi

    install -o root -g root -m 0644 "$source" "$cible"

    # Si la nouvelle config est invalide, on remet l'ancienne (déjà validée
    # lors d'un passage précédent) ou, à défaut, on retire la nôtre : ainsi
    # sshd garde au prochain redémarrage la config d'avant, pas une config cassée.
    if ! sshd -t; then
        if [ -f "$sauvegarde" ]; then
            mv "$sauvegarde" "$cible"
        else
            rm -f "$cible"
        fi
        erreur "configuration SSH invalide, ancienne configuration remise, ssh n'est pas redémarré"
        exit 1
    fi

    rm -f "$sauvegarde"
    systemctl restart ssh
    echo "SSH durci et redémarré."
}

# installer_pare_feu : installe le pare-feu nftables (config/nftables.conf).
# Risque : un pare-feu faux peut couper SSH. Précautions :
#   - nft -c -f vérifie la syntaxe SANS rien appliquer ; si le fichier est
#     mauvais, on s'arrête avant de copier quoi que ce soit ;
#   - SSH (port 22) et les connexions déjà établies sont autorisés par le
#     fichier lui-même, donc la session en cours survit au chargement.
# Le fichier ne contient pas "flush ruleset" : recharger ne touche pas la table
# f2b-table de fail2ban. Ne JAMAIS faire "systemctl restart nftables" à la main :
# l'arrêt du service exécute "nft flush ruleset" et effacerait cette table.
installer_pare_feu() {
    echo "==> Pare-feu"
    local source="${DOSSIER_DEPOT}/config/nftables.conf"

    if ! nft -c -f "$source"; then
        erreur "nftables.conf invalide : le pare-feu n'est pas modifié"
        exit 1
    fi

    install -o root -g root -m 0644 "$source" /etc/nftables.conf

    # enable = démarrage automatique au boot ; --now = démarre tout de suite si
    # le service est arrêté. Le reload applique ensuite le fichier même si le
    # service tournait déjà (relance du script).
    systemctl enable --now nftables
    systemctl reload nftables
    echo "Pare-feu nftables actif."
}

# installer_fail2ban : installe la prison sshd (config/fail2ban/jail.d).
# fail2ban est redémarré APRÈS nftables : si nftables a effacé des tables,
# fail2ban recrée ainsi la sienne et reprend ses bans.
installer_fail2ban() {
    echo "==> fail2ban"
    install -o root -g root -m 0644 "${DOSSIER_DEPOT}/config/fail2ban/jail.d/sshd-pixelia.conf" /etc/fail2ban/jail.d/sshd-pixelia.conf

    # fail2ban-client -t teste la configuration sans rien démarrer.
    if ! fail2ban-client -t >/dev/null; then
        erreur "configuration fail2ban invalide"
        exit 1
    fi

    systemctl enable fail2ban
    systemctl restart fail2ban
    echo "fail2ban actif."
}

# installer_journal : le journal systemd survit aux redémarrages
# (config/journald.conf.d/10-persistent.conf, Storage=persistent).
installer_journal() {
    echo "==> Journal persistant"
    install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
    install -o root -g root -m 0644 "${DOSSIER_DEPOT}/config/journald.conf.d/10-persistent.conf" /etc/systemd/journald.conf.d/10-persistent.conf

    # Le redémarrage de journald lui fait relire sa configuration ; --flush
    # recopie ensuite le journal de /run (volatil) vers /var/log/journal.
    systemctl restart systemd-journald
    journalctl --flush
    echo "Journal persistant."
}

# installer_mises_a_jour : mises à jour de sécurité automatiques (D1).
installer_mises_a_jour() {
    echo "==> Mises à jour automatiques"
    install -o root -g root -m 0644 "${DOSSIER_DEPOT}/config/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable --now unattended-upgrades
    echo "Mises à jour automatiques actives."
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
    installer_ssh
    installer_pare_feu
    installer_fail2ban
    installer_journal
    installer_mises_a_jour
    echo "Installation terminée."
}

verifier_usage "$#"
verifier_root
main
