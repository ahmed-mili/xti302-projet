#!/usr/bin/env bash
#
# sauvegarde.sh : sauvegarde /etc et /srv dans une nouvelle version datée.
#
# Usage : sudo sauvegarde.sh
#
# Chaque passage crée /sauvegardes/versions/AAAA-MM-JJ_HHMMSS/ qui contient
# etc/ et srv/. Les fichiers qui n'ont pas changé depuis la version précédente
# ne sont pas recopiés : rsync fait un lien dur vers l'ancienne copie
# (--link-dest). Chaque version paraît complète, mais le disque ne stocke que
# les changements. Le lien "derniere" désigne toujours la version la plus
# récente. On garde les 7 versions les plus récentes.
#
# Le script est lancé chaque nuit par sauvegarde.timer (systemd). Il écrit son
# début, sa fin et ses erreurs dans le journal : journalctl -t sauvegarde
#
# Codes de sortie :
#   0  sauvegarde réussie
#   1  erreur (mauvais usage, disque non monté, rsync en échec...)
#   3  lancé sans root
set -euo pipefail

# Où est le disque de sauvegarde et où vont les versions.
POINT_DE_MONTAGE="/sauvegardes"
DOSSIER_VERSIONS="${POINT_DE_MONTAGE}/versions"

# Ce qu'on sauvegarde.
SOURCES=(/etc /srv)

# Nombre de versions conservées : les plus anciennes sont supprimées.
NB_VERSIONS_GARDEES=7

# ---------------------------------------------------------------------------
# Messages et journal
# ---------------------------------------------------------------------------

# journaliser <message> : écrit une ligne dans le journal systemd
# (journalctl -t sauvegarde) et l'affiche aussi à l'écran.
journaliser() {
    logger -t sauvegarde "$1"
    echo "$1"
}

# echec <message> : écrit l'erreur dans le journal et sur la sortie d'erreur,
# puis arrête le script avec le code 1. -p user.err donne au message la
# priorité « erreur ».
echec() {
    logger -t sauvegarde -p user.err "erreur : $1"
    echo "erreur : $1" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Vérifications de départ
# ---------------------------------------------------------------------------

# verifier_usage <nombre d'arguments> : le script n'attend aucun argument.
verifier_usage() {
    if [ "$1" -ne 0 ]; then
        echo "usage : sudo $0" >&2
        exit 1
    fi
}

# verifier_root : lire tout /etc et /srv et garder les propriétaires exige root.
verifier_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "erreur : ce script doit être lancé en root" >&2
        exit 3
    fi
}

# verifier_disque : refuse de travailler si le disque n'est pas monté.
# Sans ce contrôle, /sauvegardes serait un simple dossier du disque système
# et la sauvegarde le remplirait.
verifier_disque() {
    if ! mountpoint -q "$POINT_DE_MONTAGE"; then
        echec "${POINT_DE_MONTAGE} n'est pas un point de montage (disque de sauvegarde absent)"
    fi
}

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

# lister_versions : affiche les noms de versions (format AAAA-MM-JJ_HHMMSS),
# de la plus ancienne à la plus récente. Ce format se trie dans l'ordre
# alphabétique comme dans l'ordre du temps. Le lien "derniere" et les copies
# en cours (.partielle) ne correspondent pas au motif : ils sont ignorés.
# grep rend 1 s'il ne trouve rien : le "|| true" évite que set -e arrête le
# script au tout premier passage, quand il n'y a encore aucune version.
lister_versions() {
    find "$DOSSIER_VERSIONS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort || true
}

# sauvegarder : copie /etc et /srv dans une nouvelle version.
#   -a  garde droits, propriétaires, dates, liens ; -A garde les ACL (sinon
#       les droits de /srv seraient perdus) ; -X garde les attributs étendus ;
#       -H garde les liens durs
#   --delete  supprime dans la copie ce qui n'existe plus à la source
# On copie d'abord dans un dossier ".partielle", renommé seulement quand rsync
# a réussi : une sauvegarde interrompue ne laisse jamais une fausse version.
sauvegarder() {
    local nouvelle="$1"
    local precedente
    local options=(-aAXH --delete)

    # Au tout premier passage il n'y a pas de version précédente : on ne met
    # pas --link-dest (il pointe vers un dossier qui n'existe pas encore).
    precedente="$(lister_versions | tail -n 1)"
    if [ -n "$precedente" ]; then
        options+=("--link-dest=${DOSSIER_VERSIONS}/${precedente}")
    fi

    # Deux sauvegardes dans la même seconde auraient le même nom : on refuse.
    if [ -e "${DOSSIER_VERSIONS}/${nouvelle}" ]; then
        echec "la version ${nouvelle} existe déjà"
    fi

    mkdir -p "${DOSSIER_VERSIONS}/${nouvelle}.partielle"

    # Sans slash final, rsync copie les dossiers eux-mêmes : on obtient etc/ et srv/.
    if ! rsync "${options[@]}" "${SOURCES[@]}" "${DOSSIER_VERSIONS}/${nouvelle}.partielle/"; then
        rm -rf "${DOSSIER_VERSIONS:?}/${nouvelle}.partielle"
        echec "rsync a échoué, la version ${nouvelle} est abandonnée"
    fi

    mv "${DOSSIER_VERSIONS}/${nouvelle}.partielle" "${DOSSIER_VERSIONS}/${nouvelle}"
}

# mettre_a_jour_lien <version> : le lien "derniere" désigne la version donnée.
# -s lien symbolique, -f remplace l'ancien lien, -n ne descend pas dans l'ancien.
mettre_a_jour_lien() {
    ln -sfn "$1" "${DOSSIER_VERSIONS}/derniere"
}

# faire_rotation : supprime les versions au-delà des NB_VERSIONS_GARDEES plus
# récentes. Les versions se partagent des fichiers par liens durs : supprimer
# une ancienne version ne casse pas les autres.
faire_rotation() {
    local version

    # head -n -7 affiche tout SAUF les 7 dernières lignes, donc les plus anciennes.
    for version in $(lister_versions | head -n "-${NB_VERSIONS_GARDEES}"); do
        rm -rf "${DOSSIER_VERSIONS:?}/${version}"
        journaliser "ancienne version supprimée : ${version}"
    done
}

# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------

# main : enchaîne les étapes.
main() {
    local version

    verifier_disque
    mkdir -p "$DOSSIER_VERSIONS"

    # Une sauvegarde interrompue (coupure de courant...) a pu laisser une
    # copie ".partielle" : on la supprime avant de recommencer.
    rm -rf "${DOSSIER_VERSIONS:?}"/*.partielle

    version="$(date +%Y-%m-%d_%H%M%S)"
    journaliser "sauvegarde commencée : ${version}"

    sauvegarder "$version"
    mettre_a_jour_lien "$version"
    faire_rotation

    journaliser "sauvegarde terminée : ${version}"
}

verifier_usage "$#"
verifier_root
main
