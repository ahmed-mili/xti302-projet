#!/usr/bin/env bash
#
# analyse_logs.sh : analyse les journaux SSH et signale les adresses IP qui
# multiplient les échecs de connexion.
#
# Usage : analyse_logs.sh [-s SEUIL] [-d DEPUIS] [-f FICHIER]
#   -s SEUIL    nombre d'échecs par adresse IP qui déclenche l'alerte (défaut : 5)
#   -d DEPUIS   début de la période, au format de "journalctl --since"
#               (défaut : "24 hours ago")
#   -f FICHIER  lit ce fichier de journal au lieu de "journalctl -u ssh"
#               (interdit au compte support, voir plus bas)
#
# Le rapport a trois parties : échecs par adresse IP, comptes visés, connexions
# réussies. Sur Debian 13, sshd écrit ses lignes sous le nom "sshd-session" :
# le script ne filtre donc jamais sur le nom du processus, seulement sur le
# texte du message ("Failed password", "Accepted"...).
#
# Codes de sortie :
#   0  aucune adresse n'atteint le seuil (un journal vide donne 0)
#   1  erreur d'usage ou fichier illisible
#   2  au moins une adresse atteint le seuil : ALERTE
#   3  lancé sans root alors que journalctl l'exige (pas de -f)
set -euo pipefail

# Valeurs par défaut des options.
SEUIL=5
DEPUIS="24 hours ago"
FICHIER=""

# ---------------------------------------------------------------------------
# Messages et usage
# ---------------------------------------------------------------------------

# erreur <message> : affiche un message d'erreur sur la sortie d'erreur.
erreur() {
    echo "erreur : $1" >&2
}

# afficher_usage : rappelle comment utiliser le script.
afficher_usage() {
    echo "usage : $0 [-s SEUIL] [-d DEPUIS] [-f FICHIER]" >&2
}

# ---------------------------------------------------------------------------
# Lecture et vérification des options
# ---------------------------------------------------------------------------

# lire_options <arguments...> : remplit SEUIL, DEPUIS et FICHIER.
lire_options() {
    local option

    while getopts ":s:d:f:" option; do
        case "$option" in
            s) SEUIL="$OPTARG" ;;
            d) DEPUIS="$OPTARG" ;;
            f) FICHIER="$OPTARG" ;;
            :) erreur "l'option -${OPTARG} demande une valeur"; afficher_usage; exit 1 ;;
            *) erreur "option inconnue : -${OPTARG}"; afficher_usage; exit 1 ;;
        esac
    done

    # Après les options, il ne doit rester aucun argument.
    shift $((OPTIND - 1))
    if [ "$#" -ne 0 ]; then
        erreur "argument en trop : $1"
        afficher_usage
        exit 1
    fi
}

# verifier_options : contrôle les valeurs reçues, sans jamais les exécuter.
#   - SEUIL : entier positif (chiffres seulement, 9 au plus, sans zéro au début) ;
#   - DEPUIS : texte non vide, passé plus loin à journalctl entre guillemets ;
#     jamais utilisé dans eval ni dans une commande construite à la main ;
#   - FICHIER : pour le compte support, l'option -f est interdite.
#     La règle sudo de support autorise ce script avec N'IMPORTE QUEL argument.
#     Avec -f, support ferait lire à root le fichier de son choix (par exemple
#     /etc/shadow) et verrait les lignes qui ressemblent à un échec SSH. Sudo
#     met le nom de l'appelant dans SUDO_USER : on refuse -f quand c'est support.
verifier_options() {
    if ! [[ "$SEUIL" =~ ^[1-9][0-9]{0,8}$ ]]; then
        erreur "le seuil doit être un entier positif (reçu : ${SEUIL})"
        afficher_usage
        exit 1
    fi

    if [ -z "$DEPUIS" ]; then
        erreur "la valeur de -d ne doit pas être vide"
        afficher_usage
        exit 1
    fi

    if [ -n "$FICHIER" ] && [ "${SUDO_USER:-}" = "support" ]; then
        erreur "l'option -f est interdite pour le compte support"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Lecture du journal
# ---------------------------------------------------------------------------

# copier_journal <destination> : écrit dans <destination> les lignes à analyser,
# soit le fichier donné avec -f, soit le journal du service ssh.
copier_journal() {
    local destination="$1"

    if [ -n "$FICHIER" ]; then
        # [ -r ] : lisible ; [ -d ] : un dossier n'est pas un journal.
        if [ ! -r "$FICHIER" ] || [ -d "$FICHIER" ]; then
            erreur "fichier illisible : ${FICHIER}"
            exit 1
        fi
        cat "$FICHIER" > "$destination"
        return
    fi

    # Sans -f, journalctl lit le journal systemd : il faut être root.
    if [ "$(id -u)" -ne 0 ]; then
        erreur "ce script doit être lancé en root (ou utiliser -f FICHIER)"
        exit 3
    fi

    # --since="..." : la valeur reste collée à l'option, entre guillemets.
    # -o short-iso : date ISO puis nom de machine, comme dans tests/.
    # --no-pager -q : pas de pager, pas de message "-- No entries --".
    if ! journalctl -u ssh --since="$DEPUIS" -o short-iso --no-pager -q > "$destination"; then
        erreur "journalctl a échoué (période : ${DEPUIS})"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Rapport
# ---------------------------------------------------------------------------

# afficher_section <titre> <fichier> : affiche un titre puis le contenu du
# fichier, ou "(aucun)" s'il est vide. [ -s ] est vrai si le fichier n'est pas vide.
afficher_section() {
    echo
    echo "=== $1 ==="
    if [ -s "$2" ]; then
        cat "$2"
    else
        echo "(aucun)"
    fi
}

# Les trois parties du rapport sont d'abord calculées dans des fichiers
# temporaires, puis affichées. Chaque calcul est une chaîne de commandes.

# calculer_echecs : garde les lignes d'échec, extrait l'adresse IPv4 de chacune
# (même expression régulière que le TP), puis compte et trie par nombre décroissant.
# "|| true" : grep rend 1 quand rien ne correspond, ce qui n'est pas une erreur ici.
calculer_echecs() {
    grep -E 'Failed password for|Invalid user|not allowed because' "$JOURNAL" \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | sort | uniq -c | sort -rn > "$ECHECS_PAR_IP" || true
}

# calculer_comptes : extrait le nom du compte visé par chaque ligne d'échec.
# sed -n ... p : n'affiche que les lignes où une substitution a réussi.
# Trois formes de lignes :
#   Failed password for [invalid user] COMPTE from ...
#   Invalid user COMPTE from ...
#   User COMPTE from ... not allowed because ...
calculer_comptes() {
    sed -nE \
        -e 's/.*Failed password for (invalid user )?([^ ]+) from .*/\2/p' \
        -e 's/.*Invalid user ([^ ]+) from .*/\1/p' \
        -e 's/.*User ([^ ]+) from .* not allowed because.*/\1/p' \
        "$JOURNAL" \
        | sort | uniq -c | sort -rn > "$COMPTES_VISES" || true
}

# calculer_connexions : les connexions réussies, "Accepted <méthode> for COMPTE
# from ADRESSE ...", affichées sous la forme "COMPTE depuis ADRESSE".
calculer_connexions() {
    sed -nE 's/.*Accepted [^ ]+ for ([^ ]+) from ([^ ]+) .*/\1 depuis \2/p' "$JOURNAL" \
        | sort | uniq -c | sort -rn > "$CONNEXIONS" || true
}

# chercher_alertes : lit "nombre adresse" ligne par ligne dans ECHECS_PAR_IP.
# Chaque adresse qui atteint le seuil donne une ligne ALERTE, écrite dans le
# fichier ALERTES. Le fichier sert de mémoire : s'il n'est pas vide à la fin,
# main sort avec le code 2.
chercher_alertes() {
    local nombre
    local adresse

    : > "$ALERTES"
    while read -r nombre adresse; do
        if [ "$nombre" -ge "$SEUIL" ]; then
            echo "ALERTE : ${adresse} a ${nombre} échecs (seuil ${SEUIL})" >> "$ALERTES"
        fi
    done < "$ECHECS_PAR_IP"
}

# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------

main() {
    lire_options "$@"
    verifier_options

    # Dossier temporaire privé (mode 0700), supprimé à la sortie quoi qu'il arrive.
    DOSSIER_TEMP="$(mktemp -d)"
    trap 'rm -rf "$DOSSIER_TEMP"' EXIT
    JOURNAL="${DOSSIER_TEMP}/journal"
    ECHECS_PAR_IP="${DOSSIER_TEMP}/echecs_par_ip"
    COMPTES_VISES="${DOSSIER_TEMP}/comptes_vises"
    CONNEXIONS="${DOSSIER_TEMP}/connexions"
    ALERTES="${DOSSIER_TEMP}/alertes"

    copier_journal "$JOURNAL"
    calculer_echecs
    calculer_comptes
    calculer_connexions
    chercher_alertes

    if [ -n "$FICHIER" ]; then
        echo "Analyse SSH : fichier ${FICHIER}, seuil ${SEUIL}"
    else
        echo "Analyse SSH : journalctl -u ssh depuis \"${DEPUIS}\", seuil ${SEUIL}"
    fi

    afficher_section "Échecs de connexion par adresse IP" "$ECHECS_PAR_IP"
    afficher_section "Comptes visés par les échecs" "$COMPTES_VISES"
    afficher_section "Connexions réussies" "$CONNEXIONS"

    echo
    echo "=== Bilan ==="
    if [ -s "$ALERTES" ]; then
        cat "$ALERTES"
        exit 2
    fi
    echo "Aucune adresse n'atteint le seuil de ${SEUIL} échecs."
    exit 0
}

main "$@"
