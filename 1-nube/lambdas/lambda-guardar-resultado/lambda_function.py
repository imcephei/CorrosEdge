import json
import unicodedata
import boto3
from decimal import Decimal

dynamodb = boto3.resource('dynamodb', region_name='us-east-2')
table = dynamodb.Table('resultados_corrosion')
tabla_dispositivos = dynamodb.Table('dispositivos')


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


def normalizar_condicion(valor):
    """
    Condicion de la lamina que detecta el modelo: con o sin incision.
    El dispositivo la manda tal como sale del modelo ("Con Incision", "Sin Incision");
    se guarda como con_incision / sin_incision. Si llega otro valor se ignora, para
    no perder la lectura de corrosion por una etiqueta mal escrita.
    """
    if valor is None:
        return None
    texto = unicodedata.normalize('NFKD', str(valor)).encode('ascii', 'ignore').decode()
    texto = texto.strip().lower().replace('-', '_').replace(' ', '_')
    if texto in ('con_incision', 'ci'):
        return 'con_incision'
    if texto in ('sin_incision', 'si'):
        return 'sin_incision'
    print(f'AVISO: condicion desconocida {valor!r}; se guarda la lectura sin ella')
    return None


def lambda_handler(event, context):
    try:
        body = json.loads(event.get('body') or '{}')

        panel_id = body.get('panel_id')
        timestamp = body.get('timestamp')
        prediccion = body.get('prediccion')
        confianza = body.get('confianza')
        imagen_key = body.get('imagen_key')
        condicion = normalizar_condicion(body.get('condicion'))

        if not panel_id or not timestamp or not prediccion:
            return respuesta(400, {'error': 'Faltan campos requeridos: panel_id, timestamp, prediccion'})

        # Cada clave solo sirve para su propio panel: un dispositivo no puede
        # reportar haciendose pasar por el de otra empresa.
        if not clave_corresponde(event, panel_id):
            return respuesta(403, {'error': f"Esta clave no esta autorizada para el panel_id '{panel_id}'"})

        # Antes, una lectura de un panel no registrado se guardaba y se respondia
        # "guardado correctamente", pero nunca aparecia en el dashboard ni
        # disparaba alertas. Ahora se rechaza con un error claro.
        if 'Item' not in tabla_dispositivos.get_item(Key={'panel_id': panel_id}):
            return respuesta(404, {
                'error': f"El panel_id '{panel_id}' no esta registrado en la tabla dispositivos"
            })

        item = {
            'panel_id': panel_id,
            'timestamp': timestamp,
            'prediccion': prediccion,
        }
        if confianza is not None:
            item['confianza'] = Decimal(str(confianza))
        if imagen_key:
            item['imagen_key'] = imagen_key
        if condicion:
            item['condicion'] = condicion

        table.put_item(Item=item)

        return respuesta(200, {'mensaje': 'Resultado guardado correctamente'})
    except Exception as e:
        return respuesta(500, {'error': str(e)})
