import json
import boto3
from decimal import Decimal
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource('dynamodb', region_name='us-east-2')
tabla_dispositivos = dynamodb.Table('dispositivos')
tabla_empresas = dynamodb.Table('empresas')
tabla_usuarios = dynamodb.Table('usuarios')
tabla_resultados = dynamodb.Table('resultados_corrosion')

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
    claims = (event.get('requestContext', {})
                   .get('authorizer', {})
                   .get('jwt', {})
                   .get('claims', {}))

    email = claims.get('email', '')

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
    todos = tabla_dispositivos.scan().get('Items', [])
    if ident['rol'] == 'admin':
        return todos
    if not ident['empresa']:
        return []
    return [d for d in todos if d.get('empresa_id') == ident['empresa']]


def ultima_lectura(panel_id):
    r = tabla_resultados.query(
        KeyConditionExpression=Key('panel_id').eq(panel_id),
        ScanIndexForward=False,
        Limit=1
    )
    items = r.get('Items', [])
    if not items:
        return None

    lectura = decimal_a_numero(items[0])
    if lectura.get('imagen_key'):
        lectura['imagen_url'] = s3.generate_presigned_url(
            ClientMethod='get_object',
            Params={'Bucket': BUCKET_NAME, 'Key': lectura['imagen_key']},
            ExpiresIn=3600
        )
    return lectura


def lambda_handler(event, context):
    try:
        ident = identidad(event)
        visibles = dispositivos_visibles(ident)

        empresas = {e['empresa_id']: e.get('nombre', e['empresa_id'])
                    for e in tabla_empresas.scan().get('Items', [])}

        salida = []
        for d in visibles:
            item = decimal_a_numero(d)
            item['empresa_nombre'] = empresas.get(item.get('empresa_id'), item.get('empresa_id'))
            item['ultima_lectura'] = ultima_lectura(item['panel_id'])
            salida.append(item)

        salida.sort(key=lambda x: x.get('nombre', ''))

        return respuesta(200, {
            'rol': ident['rol'],
            'empresa': ident['empresa'],
            'dispositivos': salida
        })

    except Exception as e:
        return respuesta(500, {'error': str(e)})
