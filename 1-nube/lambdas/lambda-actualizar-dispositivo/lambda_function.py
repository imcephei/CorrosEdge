import json
import boto3
from datetime import datetime, timezone
from decimal import Decimal

dynamodb = boto3.resource('dynamodb', region_name='us-east-2')
tabla_dispositivos = dynamodb.Table('dispositivos')
tabla_usuarios = dynamodb.Table('usuarios')

# Campos que se pueden modificar desde el dashboard.
# panel_id y empresa_id quedan fuera a proposito: uno es la llave del registro,
# y el otro define de quien es el dispositivo. Si un moderador pudiera cambiar
# empresa_id, podria asignarse un dispositivo de la otra empresa.
CAMPOS_EDITABLES = {
    'nombre': 'texto',
    'ubicacion_texto': 'texto',
    'frecuencia_horas': 'entero',
    'lat': 'decimal',
    'lon': 'decimal',
    'activo': 'booleano',
    # Instante de la primera foto (ISO 8601). Desde ahi, una foto cada frecuencia_horas.
    # null o '' lo quita y el dispositivo vuelve a contar solo desde su ultima foto.
    'inicio_muestreo': 'fecha'
}


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


def convertir(campo, tipo, valor):
    """Devuelve (valor_convertido, error)."""
    try:
        if tipo == 'entero':
            v = int(valor)
            if campo == 'frecuencia_horas' and not (1 <= v <= 168):
                return None, 'La frecuencia debe estar entre 1 y 168 horas'
            return v, None

        if tipo == 'decimal':
            v = float(valor)
            if campo == 'lat' and not (-90 <= v <= 90):
                return None, 'La latitud debe estar entre -90 y 90'
            if campo == 'lon' and not (-180 <= v <= 180):
                return None, 'La longitud debe estar entre -180 y 180'
            return Decimal(str(v)), None

        if tipo == 'booleano':
            return bool(valor), None

        if tipo == 'fecha':
            if valor is None or str(valor).strip() == '':
                return None, None          # se quita el campo
            texto = str(valor).strip()
            momento = datetime.fromisoformat(texto.replace('Z', '+00:00'))
            if momento.tzinfo is None:
                return None, 'La fecha de inicio debe incluir la zona horaria'
            return momento.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), None

        texto = str(valor).strip()
        if not texto:
            return None, 'El campo ' + campo + ' no puede quedar vacio'
        if len(texto) > 120:
            return None, 'El campo ' + campo + ' es demasiado largo'
        return texto, None

    except (TypeError, ValueError):
        return None, 'Valor invalido para ' + campo


def lambda_handler(event, context):
    try:
        ident = identidad(event)

        if ident['rol'] == 'viewer':
            return respuesta(403, {'error': 'Su rol solo permite consultar, no modificar'})

        body = json.loads(event.get('body', '{}'))
        panel_id = body.get('panel_id')
        if not panel_id:
            return respuesta(400, {'error': 'Falta el campo requerido: panel_id'})

        actual = tabla_dispositivos.get_item(Key={'panel_id': panel_id}).get('Item')
        if not actual:
            return respuesta(404, {'error': 'El dispositivo no existe'})

        # El dueno real se lee de la base de datos, no de lo que mande el cliente.
        if ident['rol'] != 'admin' and actual.get('empresa_id') != ident['empresa']:
            return respuesta(403, {'error': 'No tiene acceso a este dispositivo'})

        cambios = {}
        quitar = []
        for campo, tipo in CAMPOS_EDITABLES.items():
            if campo not in body:
                continue
            valor, error = convertir(campo, tipo, body[campo])
            if error:
                return respuesta(400, {'error': error})
            if valor is None:
                quitar.append(campo)
            else:
                cambios[campo] = valor

        if not cambios and not quitar:
            return respuesta(400, {'error': 'No se envio ningun campo modificable'})

        partes = []
        if cambios:
            partes.append('SET ' + ', '.join('#' + k + ' = :' + k for k in cambios))
        if quitar:
            partes.append('REMOVE ' + ', '.join('#' + k for k in quitar))
        nombres = {'#' + k: k for k in list(cambios) + quitar}
        params = {
            'Key': {'panel_id': panel_id},
            'UpdateExpression': ' '.join(partes),
            'ExpressionAttributeNames': nombres,
            'ReturnValues': 'ALL_NEW'
        }
        if cambios:
            params['ExpressionAttributeValues'] = {':' + k: v for k, v in cambios.items()}

        r = tabla_dispositivos.update_item(**params)

        return respuesta(200, {
            'mensaje': 'Dispositivo actualizado',
            'dispositivo': decimal_a_numero(r.get('Attributes', {}))
        })

    except Exception as e:
        return respuesta(500, {'error': str(e)})
