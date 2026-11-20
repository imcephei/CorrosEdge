import json
import boto3

dynamodb = boto3.resource('dynamodb', region_name='us-east-2')
tabla_dispositivos = dynamodb.Table('dispositivos')

FRECUENCIA_POR_DEFECTO = 24


def respuesta(codigo, cuerpo):
    return {
        'statusCode': codigo,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps(cuerpo)
    }


def panel_de_la_clave(event):
    """Igual que en guardar-resultado: '*' es la clave vieja, None es invocacion directa."""
    autorizador = (event.get('requestContext') or {}).get('authorizer') or {}
    return (autorizador.get('lambda') or autorizador).get('panel_id')


def lambda_handler(event, context):
    """
    GET /config  ->  configuracion que el dispositivo debe obedecer.
    El panel sale de la clave: cada dispositivo solo puede leer la suya.
    """
    try:
        panel_clave = panel_de_la_clave(event)
        pedido = (event.get('queryStringParameters') or {}).get('panel_id')

        if panel_clave in (None, '*'):
            panel_id = pedido
        else:
            if pedido and pedido != panel_clave:
                return respuesta(403, {'error': f"Esta clave no esta autorizada para el panel_id '{pedido}'"})
            panel_id = panel_clave

        if not panel_id:
            return respuesta(400, {'error': 'Falta el parametro panel_id'})

        item = tabla_dispositivos.get_item(Key={'panel_id': panel_id}).get('Item')
        if not item:
            return respuesta(404, {'error': f"El panel_id '{panel_id}' no esta registrado en la tabla dispositivos"})

        return respuesta(200, {
            'panel_id': panel_id,
            'frecuencia_horas': int(item.get('frecuencia_horas') or FRECUENCIA_POR_DEFECTO),
            'activo': bool(item.get('activo', True)),
            'inicio_muestreo': item.get('inicio_muestreo')
        })
    except Exception as e:
        return respuesta(500, {'error': str(e)})
