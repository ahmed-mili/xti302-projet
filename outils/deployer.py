"""Poste client Windows : envoie le dépôt dans la VM et y lance des commandes.

Usage :
    python outils/deployer.py envoyer
    python outils/deployer.py lancer "<commande>"

Le mot de passe sudo de la VM n'est jamais écrit dans le dépôt : il est lu dans
la variable d'environnement VM_SUDO_MDP.
    PowerShell : $env:VM_SUDO_MDP = '...'
"""

import io
import os
import sys
import tarfile
import time

import paramiko

# --- Réglages de la connexion (à adapter si la VM change) ---
HOTE = "192.168.216.133"
UTILISATEUR = "ahmed"
CHEMIN_CLE = os.path.expanduser("~/.ssh/vm_tp_ed25519")

# Dossier du dépôt (le dossier qui contient outils/) et dossier cible dans la VM.
DOSSIER_DEPOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOSSIER_VM = "projet"  # relatif au répertoire personnel : ~/projet

# Dossiers qu'on n'envoie jamais dans la VM.
DOSSIERS_EXCLUS = {".git", ".superpowers", "__pycache__"}


def lire_mot_de_passe():
    """Renvoie le mot de passe de la VM, ou None si la variable n'est pas définie."""
    return os.environ.get("VM_SUDO_MDP")


def se_connecter():
    """Ouvre la connexion SSH : la clé d'abord, le mot de passe en repli."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    # Premier essai : la clé privée.
    try:
        client.connect(
            HOTE,
            username=UTILISATEUR,
            key_filename=CHEMIN_CLE,
            look_for_keys=False,
            allow_agent=False,
            timeout=15,
        )
        return client
    except (paramiko.AuthenticationException, paramiko.SSHException, OSError) as erreur:
        print(f"Connexion par clé impossible ({erreur}), essai avec le mot de passe.", file=sys.stderr)

    # Repli : le mot de passe de la variable VM_SUDO_MDP.
    mot_de_passe = lire_mot_de_passe()
    if mot_de_passe is None:
        print("Erreur : la variable d'environnement VM_SUDO_MDP n'est pas définie.", file=sys.stderr)
        sys.exit(2)
    client.connect(
        HOTE,
        username=UTILISATEUR,
        password=mot_de_passe,
        look_for_keys=False,
        allow_agent=False,
        timeout=15,
    )
    return client


def fabriquer_archive():
    """Construit en mémoire une archive tar du dépôt (sans .git ni .superpowers)."""
    tampon = io.BytesIO()
    with tarfile.open(fileobj=tampon, mode="w") as archive:
        for dossier, sous_dossiers, fichiers in os.walk(DOSSIER_DEPOT):
            # On retire les dossiers exclus de la liste pour que os.walk n'y entre pas.
            sous_dossiers[:] = [d for d in sous_dossiers if d not in DOSSIERS_EXCLUS]
            for nom in fichiers:
                chemin = os.path.join(dossier, nom)
                nom_dans_archive = os.path.relpath(chemin, DOSSIER_DEPOT).replace(os.sep, "/")
                with open(chemin, "rb") as f:
                    contenu = f.read()

                # Un script .sh doit avoir des fins de ligne Unix et être exécutable.
                if nom.endswith(".sh"):
                    contenu = contenu.replace(b"\r\n", b"\n")
                    droits = 0o755
                else:
                    droits = 0o644

                info = tarfile.TarInfo(nom_dans_archive)
                info.size = len(contenu)
                info.mode = droits
                info.mtime = int(time.time())
                archive.addfile(info, io.BytesIO(contenu))
    return tampon.getvalue()


def envoyer():
    """Recrée ~/projet dans la VM et y extrait le dépôt. Renvoie le code de sortie."""
    donnees = fabriquer_archive()
    client = se_connecter()
    try:
        # On repart d'un dossier vide, on extrait l'archive lue sur l'entrée standard,
        # puis on rend tous les .sh exécutables.
        commande = (
            f"rm -rf ~/{DOSSIER_VM} && mkdir -p ~/{DOSSIER_VM} && "
            f"tar -xf - -C ~/{DOSSIER_VM} && "
            f"find ~/{DOSSIER_VM} -name '*.sh' -exec chmod +x {{}} +"
        )
        entree, sortie, erreur = client.exec_command(commande)
        entree.write(donnees)
        entree.channel.shutdown_write()
        code = sortie.channel.recv_exit_status()
        texte_erreur = erreur.read().decode("utf-8", errors="replace")
        if code != 0:
            print(f"Échec de l'envoi (code {code}) : {texte_erreur}", file=sys.stderr)
        else:
            print(f"Dépôt envoyé dans ~/{DOSSIER_VM} ({len(donnees)} octets).")
        return code
    finally:
        client.close()


def lancer(commande):
    """Exécute la commande dans ~/projet et renvoie son code de sortie."""
    mot_de_passe = lire_mot_de_passe()
    avec_sudo = commande.startswith("sudo")
    if avec_sudo:
        if mot_de_passe is None:
            print("Erreur : la variable d'environnement VM_SUDO_MDP n'est pas définie.", file=sys.stderr)
            return 2
        # sudo -S lit le mot de passe sur l'entrée standard, -p '' supprime l'invite.
        commande = "sudo -S -p '' " + commande[len("sudo"):].lstrip()

    client = se_connecter()
    try:
        entree, sortie, erreur = client.exec_command(f"cd ~/{DOSSIER_VM} && {commande}")
        if avec_sudo:
            entree.write(mot_de_passe + "\n")
        entree.channel.shutdown_write()

        # On recopie les sorties au fil de l'eau, en octets bruts : ce sont déjà
        # de l'UTF-8, donc les accents s'affichent bien quelle que soit la console.
        canal = sortie.channel
        while True:
            if canal.recv_ready():
                sys.stdout.buffer.write(canal.recv(4096))
                sys.stdout.buffer.flush()
            if canal.recv_stderr_ready():
                sys.stderr.buffer.write(canal.recv_stderr(4096))
                sys.stderr.buffer.flush()
            if canal.exit_status_ready() and not canal.recv_ready() and not canal.recv_stderr_ready():
                break
            time.sleep(0.02)
        return canal.recv_exit_status()
    finally:
        client.close()


def main():
    """Lit la ligne de commande et appelle envoyer ou lancer."""
    if len(sys.argv) == 2 and sys.argv[1] == "envoyer":
        return envoyer()
    if len(sys.argv) == 3 and sys.argv[1] == "lancer":
        return lancer(sys.argv[2])
    print('usage : python outils/deployer.py envoyer | lancer "<commande>"', file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
