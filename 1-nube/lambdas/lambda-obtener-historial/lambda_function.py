import json
import boto3
from decimal import Decimal
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource('dynamodb', region_name='us-east-2')
tabla_resultados = dynamodb.Table('resultados_corrosion')
tabla_dispositivos = dynamodb.Table('dispositivos')
tabla_usuarios = dynamodb.Table('usuarios')

s3 = boto3.client('s3', region_name='us-east-2')
BUCKET_NAME = 'imagenes-corrosion-detector'


def respuesta(codigo, cuerpo):
    return {
        'statusCode': codigo,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'
        },
        'body': json.dumps(cuerpo)
    }


def decimal_a_numero(obj):
    if isinstance(obj, list):
        return [decimal_a_numero(i) for i in obj]
    if isinstance(obj, dict):
        return {k: decimal_a_numero(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return float(obj)
    return obj


def identidad(event):
    """Lee quien es el usuario desde el token que API Gateway ya valido."""
    claims = (event.get('requestContext', {})
                   .get('authorizer', {})
                   .get('jwt', {})
                   .get('claims', {}))

    email = claims.get('email', '')

    # cognito:groups puede llegar como lista o como texto "[admin]"
    grupos_raw = claims.get('cognito:groups', '')
    if isinstance(grupos_raw, list):
        grupos = grupos_raw
    else:
        grupos = grupos_raw.strip('[]').replace(',', ' ').split()

    if 'admin' in grupos:
        rol = 'admin'
    elif 'moderador' in grupos:
        rol = 'moderador'
    else:
        rol = 'viewer'

    empresa = None
    if rol != 'admin' and email:
        item = tabla_usuarios.get_item(Key={'email': email}).get('Item')
        if item:
            empresa = item.get('empresa_id')

    return {'email': email, 'rol': rol, 'empresa': empresa}


def dispositivos_visibles(ident):
    """El admin ve todos; los demas solo los de su empresa."""
    todos = tabla_dispositivos.scan().get('Items', [])
    if ident['rol'] == 'admin':
        return todos
    if not ident['empresa']:
        return []
    return [d for d in todos if d.get('empresa_id') == ident['empresa']]


def agregar_url_imagen(item):
    if item.get('imagen_key'):
        item['imagen_url'] = s3.generate_presigned_url(
            ClientMethod='get_object',
            Params={'Bucket': BUCKET_NAME, 'Key': item['imagen_key']},
            ExpiresIn=3600
        )
    return item


def lambda_handler(event, context):
    try:
        ident = identidad(event)
        visibles = dispositivos_visibles(ident)
        permitidos = {d['panel_id'] for d in visibles}
        nombres = {d['panel_id']: d.get('nombre', d['panel_id']) for d in visibles}

        params = event.get('queryStringParameters') or {}
        pedido = params.get('panel_id')

        if pedido:
            # Aqui esta la clave: no basta con que pida un panel, tiene que
            # estar dentro de los que su rol/empresa le permiten ver.
            if pedido not in permitidos:
                return respuesta(403, {'error': 'No tiene acceso a este dispositivo'})
            objetivo = [pedido]
        else:
            objetivo = sorted(permitidos)

        items = []
        for pid in objetivo:
            r = tabla_resultados.query(
                KeyConditionExpression=Key('panel_id').eq(pid),
                ScanIndexForward=False
            )
            for it in r.get('Items', []):
                it['nombre_dispositivo'] = nombres.get(pid, pid)
                items.append(it)

        items.sort(key=lambda i: i.get('timestamp', ''), reverse=True)
        items = [agregar_url_imagen(i) for i in decimal_a_numero(items)]

        return respuesta(200, {
            'rol': ident['rol'],
            'empresa': ident['empresa'],
            'resultados': items
        })

    except Exception as e:
        return respuesta(500, {'error': str(e)})
