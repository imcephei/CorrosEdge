import json
import uuid
import boto3
from datetime import datetime, timezone

s3 = boto3.client('s3', region_name='us-east-2')
dynamodb = boto3.resource('dynamodb', region_name='us-east-2')
tabla_dispositivos = dynamodb.Table('dispositivos')
BUCKET_NAME = 'imagenes-corrosion-detector'


def respuesta(codigo, cuerpo):
    return {
        'statusCode': codigo,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps(cuerpo)
    }


def panel_de_la_clave(event):
    """
    Panel al que pertenece la clave con la que llego la peticion (lo pone el
    autorizador). '*' es la clave compartida antigua; None significa que se
    invoco la Lambda directamente con credenciales de AWS, sin pasar por la API.
    """
    autorizador = (event.get('requestContext') or {}).get('authorizer') or {}
    return (autorizador.get('lambda') or autorizador).get('panel_id')


def clave_corresponde(event, panel_id):
    panel_clave = panel_de_la_clave(event)
    return panel_clave in (None, '*') or panel_clave == panel_id


def lambda_handler(event, context):
    try:
        body = json.loads(event.get('body') or '{}')

        panel_id = body.get('panel_id')

        if not panel_id:
            return respuesta(400, {'error': 'Falta el campo requerido: panel_id'})

        # Cada clave solo sirve para su propio panel: un dispositivo no puede
        # reportar haciendose pasar por el de otra empresa.
        if not clave_corresponde(event, panel_id):
            return respuesta(403, {'error': f"Esta clave no esta autorizada para el panel_id '{panel_id}'"})

        # Solo se firma la subida si el panel esta registrado. Asi un dispositivo
        # mal configurado se entera de inmediato, antes de subir la foto, y no
        # quedan fotos huerfanas en el bucket que nadie va a ver.
        if 'Item' not in tabla_dispositivos.get_item(Key={'panel_id': panel_id}):
            return respuesta(404, {
                'error': f"El panel_id '{panel_id}' no esta registrado en la tabla dispositivos"
            })

        # La Lambda genera la ruta con su propio reloj (UTC) + un sufijo aleatorio.
        # Asi dos dispositivos nunca pueden sobrescribirse la foto entre si,
        # ni aunque suban en el mismo segundo o tengan el reloj mal configurado.
        ahora = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H-%M-%S')
        sufijo = uuid.uuid4().hex[:6]
        imagen_key = f'paneles/{panel_id}/{ahora}-{sufijo}.jpg'

        url = s3.generate_presigned_url(
            ClientMethod='put_object',
            Params={
                'Bucket': BUCKET_NAME,
                'Key': imagen_key,
                'ContentType': 'image/jpeg'
            },
            ExpiresIn=300
        )

        return respuesta(200, {'upload_url': url, 'imagen_key': imagen_key})
    except Exception as e:
        return respuesta(500, {'error': str(e)})
