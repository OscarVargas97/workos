# Punto de entrada único a estos scripts: qué correr, cuándo, sin tener
# que recordar el contexto de cómo quedó la migración la última vez.
# `make` sin nada = `make help`.
.DEFAULT_GOAL := help

help:
	@echo "Paso 0 - opcional, en la máquina vieja (solo referencia):"
	@echo "  make audit                 - audita la instalación actual (read-only, .md)"
	@echo
	@echo "Paso 1 - una vez por máquina nueva, antes de instalar:"
	@echo "  make usb                   - graba+prepara el pendrive (elegís cuál, conectado)"
	@echo
	@echo "Paso 2 - instalación. OJO: particiona y BORRA la máquina destino:"
	@echo "  make deploy                - instala NixOS de punta a punta (nixos-anywhere)"
	@echo
	@echo "Paso 3 - recién reinició con NixOS ya instalado. Re-corrible si algo falla:"
	@echo "  make post-install          - TPM2, gh, clone workos + workos-private, vault, Twingate"
	@echo
	@echo "Paso 4 - cuando quieras traer TUS datos a la máquina ya instalada:"
	@echo "  make map-list              - lista tus repos y a dónde va cada uno (Repos/<Empresa> o Externos)"
	@echo "  make map                   - pregunta el destino de los repos sin mapear"
	@echo "  make migrate               - repos reales, ssh, gh/docker/aws, DBeaver, Chrome"
	@echo
	@echo "Opcional - antes de migrar, si tenés .env/.sql sueltos sin respaldar en vault/:"
	@echo "  make collect-secrets       - solo LISTA qué encontraría (default, no copia nada)"
	@echo "  make collect-secrets-copy  - copia de verdad a ~/Repos/Externos/workos/vault"

audit:
	./audit-fedora.sh

usb:
	./prepare-installer-usb.sh

deploy:
	./nixos-anywhere-deploy.sh

post-install:
	./post-install-setup.sh

map-list:
	./map-repos.sh --list

map:
	./map-repos.sh

migrate:
	./migrate-pc.sh

collect-secrets:
	./collect-configs.sh

collect-secrets-copy:
	./collect-configs.sh --copy

.PHONY: help audit usb deploy post-install map-list map migrate collect-secrets collect-secrets-copy
