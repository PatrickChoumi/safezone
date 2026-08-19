#!/bin/sh
# blocker-adulte — point d'entree dracut au demarrage (composant 4)
#
# Installe dans l'image par le module 99blocker-adulte, execute en pre-pivot :
# apres le montage du disque racine, juste avant le switch_root.
#
# ATTENTION : dracut ne LANCE pas ce fichier, il le SOURCE depuis son processus
# init. Un « exit » ici arreterait l'init du systeme et rendrait la machine non
# demarrable. Ce script n'en contient donc aucun — c'est la seule difference
# avec son equivalent initramfs-tools, et elle est essentielle.

if [ -x /usr/sbin/blocker-adulte-load-rules ]; then
    /usr/sbin/blocker-adulte-load-rules || :
elif command -v warn >/dev/null 2>&1; then
    warn "blocker-adulte: chargeur absent de l'image, regles de base non chargees"
else
    echo "blocker-adulte (initramfs): chargeur absent de l'image, regles non chargees"
fi
