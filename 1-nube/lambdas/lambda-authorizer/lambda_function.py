import os
import json
import hmac
import hashlib

# Cada dispositivo tiene su propia clave. Aqui no se guardan las claves sino su
# huella SHA-256, amarrada al panel que esa clave puede reportar:
#   DEVICE_KEYS = {"<sha256 de la clave>": "P-ACR-001", ...}
# Asi, aunque alguien lea la configuracion de esta Lambda, no obtiene las claves.
CLAVES = json.loads(os.environ.get('DEVICE_KEYS') or '{}')

# Clave compartida antigua. Solo para la transicion: mientras exista, sigue
# funcionando sin amarre a ningun panel. Se borra la variable cuando todos los
# dispositivos tengan su clave propia.
API_SECRET = os.environ.get('API_SECRET')


def lambda_handler(event, context):
    headers = event.get('headers') or {}
    api_key = headers.get('x-api-key') or headers.get('X-Api-Key') or ''
    if not api_key:
        return {'isAuthorized': False}

    huella = hashlib.sha256(api_key.encode('utf-8')).hexdigest()
    panel_id = CLAVES.get(huella)
    if panel_id:
        # El panel viaja a la Lambda de destino, que verifica que coincida
        # con el panel_id que el dispositivo dice reportar.
        return {'isAuthorized': True, 'context': {'panel_id': panel_id}}

    if API_SECRET and hmac.compare_digest(api_key, API_SECRET):
        # Queda en el log para saber si algun dispositivo sigue con la clave
        # vieja antes de borrarla (pruebas-api\quitar-clave-vieja.ps1 lo revisa).
        print('CLAVE_VIEJA_USADA')
        return {'isAuthorized': True, 'context': {'panel_id': '*'}}

    return {'isAuthorized': False}
