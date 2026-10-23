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

    # On remplace les virgules par des espaces pour parcourir la liste.
    for groupe in ${secondaires//,/ }; do
        creer_groupe "$groupe"
        usermod -aG "$groupe" "$login"
    done
}

# installer_cle <login> <groupe principal> : copie cles/<login>.pub dans
# ~login/.ssh/authorized_keys avec les droits que SSH exige (700 et 600).
installer_cle() {
    local login="$1"
    local principal="$2"
    local fichier_cle="${DOSSIER_CLES}/${login}.pub"
    local home
    local dossier_ssh

    if [ ! -f "$fichier_cle" ]; then
        return 0
    fi

    home="$(getent passwd "$login" | cut -d: -f6)"
    dossier_ssh="${home}/.ssh"

    mkdir -p "$dossier_ssh"
    cp "$fichier_cle" "${dossier_ssh}/authorized_keys"
    chown -R "${login}:${principal}" "$dossier_ssh"
    chmod 700 "$dossier_ssh"
    chmod 600 "${dossier_ssh}/authorized_keys"
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
    installer_cle "$login" "$principal"

    # Les freelance ont un compte à durée limitée.
    if [ "$principal" = "freelance" ]; then
        chage -E "$DATE_EXPIRATION_FREELANCE" "$login"
    fi
}

# lire_csv <fichier> : lit le CSV ligne par ligne, saute l'en-tête et les
# lignes vides. tr -d '\r' retire les retours chariot au cas où le fichier
# aurait été enregistré avec des fins de ligne Windows.
lire_csv() {
    local fichier="$1"
    local login nom principal secondaires

    while IFS=';' read -r login nom principal secondaires || [ -n "$login" ]; do
        if [ -z "$login" ]; then
            continue
        fi
        if [ -z "$principal" ]; then
            erreur "ligne incomplète dans ${fichier} (login ${login})"
            exit 1
        fi
        traiter_ligne "$login" "$nom" "$principal" "$secondaires"
    done < <(tail -n +2 "$fichier" | tr -d '\r')
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
    setfacl -m g:dev:rwx,g:design:r-x,g:freelance:--x /srv/projets
    setfacl -d -m g:dev:rwx,g:design:r-x,g:freelance:--x,o::--- /srv/projets

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

    lire_csv "$fichier_csv"
    creer_dossiers_srv
}

verifier_usage "$#"
verifier_root
main "$@"
