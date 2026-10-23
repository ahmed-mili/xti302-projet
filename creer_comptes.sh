#!/usr/bin/env bash
#
# creer_comptes.sh : crée les groupes, les comptes et les répertoires de /srv
# décrits dans comptes.csv (exigences C1 et C2).
#
# Usage : sudo ./creer_comptes.sh [fichier_csv]
#         (par défaut : comptes.csv à côté du script)
#
# Le script est idempotent : on peut le relancer sans erreur et sans créer de
# doublon. Un compte qui existe déjà (comme ahmed) n'est pas recréé : on lui
# met seulement ses groupes.
#
# Codes de sortie : 0 tout va bien, 1 erreur pendant le travail, 2 mauvais usage.
set -euo pipefail

# Dossier où se trouve ce script : on y cherche comptes.csv et cles/.
DOSSIER_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
DOSSIER_CLES="${DOSSIER_SCRIPT}/cles"

# Date d'expiration des comptes freelance : fin du semestre.
DATE_EXPIRATION_FREELANCE="2027-01-31"

# ---------------------------------------------------------------------------
# Vérifications de départ
# ---------------------------------------------------------------------------

# erreur <message> : affiche un message d'erreur sur la sortie d'erreur.
erreur() {
    echo "erreur : $1" >&2
}

# verifier_usage <nombre d'arguments> : le script accepte 0 ou 1 argument.
verifier_usage() {
    if [ "$1" -gt 1 ]; then
        echo "usage : sudo $0 [fichier_csv]" >&2
        exit 2
    fi
}

# verifier_root : useradd, setfacl, chown... exigent root.
verifier_root() {
    if [ "$(id -u)" -ne 0 ]; then
        erreur "ce script doit être lancé en root"
        exit 2
    fi
}

# ---------------------------------------------------------------------------
# Groupes et comptes
# ---------------------------------------------------------------------------

# creer_groupe <groupe> : crée le groupe seulement s'il n'existe pas déjà.
creer_groupe() {
    local groupe="$1"

    if getent group "$groupe" >/dev/null; then
        return 0
    fi
    groupadd "$groupe"
    echo "groupe créé : ${groupe}"
}

# creer_compte <login> <nom> <groupe principal> : crée le compte s'il est
# absent ; s'il existe déjà, on remet seulement son groupe principal.
creer_compte() {
    local login="$1"
    local nom="$2"
    local principal="$3"

    if id "$login" >/dev/null 2>&1; then
        if [ "$(id -gn "$login")" != "$principal" ]; then
            usermod -g "$principal" "$login"
        fi
        echo "compte existant : ${login}"
        return 0
    fi
    # -m crée le home, -s donne bash, -g le groupe principal, -c le nom complet.
    # Aucun mot de passe n'est défini : le compte est verrouillé par défaut.
    useradd -m -s /bin/bash -g "$principal" -c "$nom" "$login"
    echo "compte créé : ${login}"
}

# ajouter_groupes_secondaires <login> <liste séparée par des virgules> :
# ajoute le compte à chaque groupe secondaire (-aG ajoute sans rien retirer).
ajouter_groupes_secondaires() {
    local login="$1"
    local secondaires="$2"
    local groupe

    # tr remplace les virgules par des espaces pour parcourir la liste avec for.
    for groupe in $(echo "$secondaires" | tr ',' ' '); do
        creer_groupe "$groupe"
        usermod -aG "$groupe" "$login"
    done
}

# installer_cle <login> : copie cles/<login>.pub dans ~login/.ssh/authorized_keys
# avec les droits que SSH exige (700 et 600).
# Sécurité : ce script tourne en root et écrit dans le home d'un utilisateur.
# Si ~/.ssh ou authorized_keys était un lien symbolique placé par cet
# utilisateur, root écrirait ailleurs (par exemple dans /etc). On refuse donc
# les liens symboliques. Mais l'utilisateur pourrait en placer un entre le test
# et l'écriture : on écrit donc AVEC SES DROITS (runuser -u), pas ceux de root.
# Un lien vers un endroit interdit à l'utilisateur échouerait alors tout seul.
# install crée le dossier et le fichier d'un coup avec le bon mode : il n'y a
# pas de moment où ils seraient mal protégés. Le propriétaire et le groupe sont
# ceux de l'utilisateur, puisque c'est lui qui crée les fichiers.
# Le fichier de la clé est donné à install sur son entrée standard (/dev/stdin).
installer_cle() {
    local login="$1"
    local fichier_cle="${DOSSIER_CLES}/${login}.pub"
    local home
    local dossier_ssh
    local fichier_cles_autorisees

    if [ ! -f "$fichier_cle" ]; then
        return 0
    fi

    home="$(getent passwd "$login" | cut -d: -f6)"
    dossier_ssh="${home}/.ssh"
    fichier_cles_autorisees="${dossier_ssh}/authorized_keys"

    if [ -L "$dossier_ssh" ] || [ -L "$fichier_cles_autorisees" ]; then
        erreur "${dossier_ssh} ou authorized_keys est un lien symbolique : on refuse d'y écrire"
        exit 1
    fi

    runuser -u "$login" -- install -d -m 0700 "$dossier_ssh"
    runuser -u "$login" -- install -m 0600 /dev/stdin "$fichier_cles_autorisees" < "$fichier_cle"
    echo "clé publique installée : ${login}"
}

# traiter_ligne <login> <nom> <principal> <secondaires> : tout ce qui concerne
# un compte du CSV, dans l'ordre : groupes, compte, groupes secondaires, clé,
# expiration.
traiter_ligne() {
    local login="$1"
    local nom="$2"
    local principal="$3"
    local secondaires="$4"

    creer_groupe "$principal"
    creer_compte "$login" "$nom" "$principal"
    ajouter_groupes_secondaires "$login" "$secondaires"
    installer_cle "$login"

    # Les freelance ont un compte à durée limitée.
    if [ "$principal" = "freelance" ]; then
        chage -E "$DATE_EXPIRATION_FREELANCE" "$login"
    fi
}

# nom_valide <texte> : renvoie 0 si le texte est un nom de login ou de groupe
# acceptable : minuscules, chiffres, _ et -, en commençant par une lettre ou _.
nom_valide() {
    printf '%s\n' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*$'
}

# groupe_interdit <groupe> : renvoie 0 pour les groupes qu'un CSV ne doit
# jamais donner à un compte (root, sudo, adm).
groupe_interdit() {
    case "$1" in
        root|sudo|adm) return 0 ;;
    esac
    return 1
}

# erreurs_ligne <login> <principal> <secondaires> : affiche une ligne par
# problème trouvé dans une ligne du CSV (rien si la ligne est correcte).
erreurs_ligne() {
    local login="$1"
    local principal="$2"
    local secondaires="$3"
    local groupe

    if ! nom_valide "$login" || [ "$login" = "root" ]; then
        echo "login invalide : '${login}'"
    fi

    for groupe in $principal $(echo "$secondaires" | tr ',' ' '); do
        if ! nom_valide "$groupe"; then
            echo "groupe invalide pour ${login} : '${groupe}'"
        elif groupe_interdit "$groupe"; then
            echo "groupe interdit pour ${login} : '${groupe}'"
        fi
    done

    if [ -z "$principal" ]; then
        echo "groupe principal manquant pour ${login}"
    fi
}

# verifier_csv <fichier> : contrôle toutes les lignes AVANT de créer quoi que
# ce soit, pour ne pas laisser le système à moitié configuré.
# tail -n +2 saute l'en-tête ; tr -d '\r' retire les retours chariot (fichier
# enregistré sous Windows) ; la boucle affiche les problèmes et $( ) les garde.
verifier_csv() {
    local fichier="$1"
    local problemes

    problemes="$(tail -n +2 "$fichier" | tr -d '\r' | while IFS=';' read -r login _nom principal secondaires || [ -n "$login" ]; do
        if [ -n "$login" ]; then
            erreurs_ligne "$login" "$principal" "$secondaires"
        fi
    done)"

    if [ -n "$problemes" ]; then
        erreur "${fichier} est invalide :"
        echo "$problemes" >&2
        exit 1
    fi
}

# lire_csv <fichier> : crée les comptes ligne par ligne, en sautant l'en-tête
# et les lignes vides. La boucle est placée après un | : si une commande
# échoue dedans, "set -e" avec "pipefail" arrête quand même tout le script.
lire_csv() {
    local fichier="$1"

    tail -n +2 "$fichier" | tr -d '\r' | while IFS=';' read -r login nom principal secondaires || [ -n "$login" ]; do
        if [ -n "$login" ]; then
            traiter_ligne "$login" "$nom" "$principal" "$secondaires"
        fi
    done
}

# ---------------------------------------------------------------------------
# Répertoires de /srv et droits (ACL)
# ---------------------------------------------------------------------------

# preparer_repertoire <chemin> : crée le répertoire, le met à root:root en
# 0770 (rien pour "other") et efface les anciennes ACL pour repartir propre.
preparer_repertoire() {
    local chemin="$1"

    mkdir -p "$chemin"
    chown root:root "$chemin"
    chmod 0770 "$chemin"
    setfacl -b "$chemin"
}

# Pour chaque répertoire, "setfacl -m" règle les droits des groupes et
# "setfacl -d -m" règle les mêmes droits par défaut, pour les futurs fichiers.
# o::--- ferme les futurs fichiers aux autres utilisateurs.
# Le freelance a seulement --x sur /srv/projets : il peut le traverser pour
# atteindre externe, sans voir la liste des projets.
creer_dossiers_srv() {
    local groupe

    # Les ACL citent ces quatre groupes : ils doivent exister.
    for groupe in dev design commercial freelance; do
        creer_groupe "$groupe"
    done

    # On crée d'abord tous les répertoires : externe est dans projets.
    preparer_repertoire /srv/projets
    preparer_repertoire /srv/projets/externe
    preparer_repertoire /srv/maquettes
    preparer_repertoire /srv/clients

    # /srv/projets : dev rw, design r, freelance traverse seulement.
    # Pas de freelance dans les ACL par défaut : traverser n'a aucun sens pour
    # de futurs fichiers.
    setfacl -m g:dev:rwx,g:design:r-x,g:freelance:--x /srv/projets
    setfacl -d -m g:dev:rwx,g:design:r-x,o::--- /srv/projets

    # /srv/projets/externe : dev rw, design r, freelance rw.
    setfacl -m g:dev:rwx,g:design:r-x,g:freelance:rwx /srv/projets/externe
    setfacl -d -m g:dev:rwx,g:design:r-x,g:freelance:rwx,o::--- /srv/projets/externe

    # /srv/maquettes : dev r, design rw, commercial r.
    setfacl -m g:dev:r-x,g:design:rwx,g:commercial:r-x /srv/maquettes
    setfacl -d -m g:dev:r-x,g:design:rwx,g:commercial:r-x,o::--- /srv/maquettes

    # /srv/clients : commercial rw seulement.
    setfacl -m g:commercial:rwx /srv/clients
    setfacl -d -m g:commercial:rwx,o::--- /srv/clients

    echo "répertoires /srv et ACL en place"
}

# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------

main() {
    local fichier_csv="${1:-${DOSSIER_SCRIPT}/comptes.csv}"

    if [ ! -f "$fichier_csv" ]; then
        erreur "fichier introuvable : ${fichier_csv}"
        exit 1
    fi

    verifier_csv "$fichier_csv"
    lire_csv "$fichier_csv"
    creer_dossiers_srv
}

verifier_usage "$#"
verifier_root
main "$@"
