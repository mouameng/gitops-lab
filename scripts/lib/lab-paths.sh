# Chemins communs du lab. À charger avec « . », jamais à exécuter.
# Ni set -e ni exit : chargé par des scripts qui gèrent leurs erreurs.
LAB_CONFIG_DIR="${LAB_CONFIG_DIR:-$HOME/.config/lab}"
LAB_DATA_DIR="${LAB_DATA_DIR:-$HOME/.local/share/lab}"
LAB_REGISTRATION_CANDIDATES_DIR="${LAB_REGISTRATION_CANDIDATES_DIR:-$LAB_CONFIG_DIR/registration-candidates}"
LAB_PRA_ISOLATED_DIR="${LAB_PRA_ISOLATED_DIR:-$LAB_CONFIG_DIR/pra-isolated}"
LAB_GITEA_BACKUP_DIR="${LAB_GITEA_BACKUP_DIR:-$LAB_DATA_DIR/backups/gitea}"
case "$LAB_CONFIG_DIR:$LAB_DATA_DIR" in
/*:/*) ;;
*) echo "[STOP] LAB_CONFIG_DIR et LAB_DATA_DIR doivent être des chemins absolus" >&2; return 1 ;;
esac
