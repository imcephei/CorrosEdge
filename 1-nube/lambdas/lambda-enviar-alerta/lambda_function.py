import json
import os
import urllib.request
import urllib.parse
import boto3
from boto3.dynamodb.conditions import Key
from boto3.dynamodb.types import TypeDeserializer

dynamodb = boto3.resource('dynamodb', region_name='us-east-2')
tabla_resultados = dynamodb.Table('resultados_corrosion')
tabla_dispositivos = dynamodb.Table('dispositivos')
tabla_empresas = dynamodb.Table('empresas')

s3 = boto3.client('s3', region_name='us-east-2')
ses = boto3.client('ses', region_name='us-east-2')

BUCKET = 'imagenes-corrosion-detector'
TELEGRAM_TOKEN = os.environ.get('TELEGRAM_TOKEN', '')
REMITENTE = os.environ.get('REMITENTE', '')
DASHBOARD_URL = os.environ.get('DASHBOARD_URL', '')

deserializador = TypeDeserializer()


def desde_stream(imagen):
    """Convierte el formato crudo del stream a un diccionario normal."""
    return {k: deserializador.deserialize(v) for k, v in imagen.items()}


def es_cambio_de_estado(panel_id):
    """
    True solo si el panel PASO a estar corroido: o es su primera lectura,
    o la anterior decia que estaba sano. Si ya venia corroido, no alertamos
    de nuevo — un panel corroido reportando a diario generaria una alerta
    diaria y la gente dejaria de leerlas.
    """
    r = tabla_resultados.query(
        KeyConditionExpression=Key('panel_id').eq(panel_id),
        ScanIndexForward=False,
        Limit=2
    )
    items = r.get('Items', [])
    if not items:
        return False
    if len(items) == 1:
        return True
    return items[1].get('prediccion') != 'con_corrosion'


def url_imagen(imagen_key):
    if not imagen_key:
        return None
    try:
        return s3.generate_presigned_url(
            ClientMethod='get_object',
            Params={'Bucket': BUCKET, 'Key': imagen_key},
            ExpiresIn=43200
        )
    except Exception as e:
        print('No se pudo firmar la imagen:', e)
        return None


def enviar_correo(destinos, dispositivo, empresa, lectura, foto):
    if not destinos or not REMITENTE:
        print('Sin destinatarios o sin remitente configurado; no se envia correo')
        return

    nombre = dispositivo.get('nombre', lectura.get('panel_id'))
    asunto = 'ALERTA de corrosion - ' + nombre

    html = """
    <div style="font-family:Arial,sans-serif;max-width:560px;color:#222">
      <div style="background:#8a3a12;color:#fff;padding:14px 18px;border-radius:4px 4px 0 0">
        <h2 style="margin:0;font-size:19px">Alerta de corrosion detectada</h2>
      </div>
      <div style="border:1px solid #ddd;border-top:0;padding:18px;border-radius:0 0 4px 4px">
        <p style="margin:0 0 14px">El sistema de monitoreo detecto corrosion en un panel
        que anteriormente no presentaba indicios.</p>
        <table style="border-collapse:collapse;font-size:14px;width:100%">
          <tr><td style="padding:5px 0;color:#666;width:135px">Dispositivo</td><td><b>{nombre}</b></td></tr>
          <tr><td style="padding:5px 0;color:#666">Identificador</td><td>{panel}</td></tr>
          <tr><td style="padding:5px 0;color:#666">Empresa</td><td>{empresa}</td></tr>
          <tr><td style="padding:5px 0;color:#666">Ubicacion</td><td>{ubicacion}</td></tr>
          <tr><td style="padding:5px 0;color:#666">Fecha del reporte</td><td>{fecha}</td></tr>
        </table>
        {bloque_foto}
        <p style="margin:18px 0 0">
          <a href="{dashboard}" style="background:#3f5b6d;color:#fff;text-decoration:none;
             padding:10px 16px;border-radius:4px;display:inline-block">Abrir el dashboard</a>
        </p>
        <p style="margin:16px 0 0;font-size:12px;color:#888">
          Mensaje automatico del sistema de monitoreo de corrosion.
          Se envia solo cuando un panel cambia de estado, no en cada lectura.
        </p>
      </div>
    </div>
    """

    bloque_foto = ''
    if foto:
        bloque_foto = ('<p style="margin:16px 0 0"><a href="' + foto + '">'
                       'Ver la fotografia del reporte</a> '
                       '<span style="font-size:12px;color:#888">(enlace temporal, 12 horas)</span></p>')

    cuerpo = html.format(
        nombre=nombre,
        panel=lectura.get('panel_id', ''),
        empresa=empresa.get('nombre', ''),
        ubicacion=dispositivo.get('ubicacion_texto', '-'),
        fecha=lectura.get('timestamp', ''),
        bloque_foto=bloque_foto,
        dashboard=DASHBOARD_URL
    )

    ses.send_email(
        Source=REMITENTE,
        Destination={'ToAddresses': destinos},
        Message={
            'Subject': {'Data': asunto, 'Charset': 'UTF-8'},
            'Body': {'Html': {'Data': cuerpo, 'Charset': 'UTF-8'}}
        }
    )
    print('Correo enviado a', destinos)


def telegram(metodo, datos):
    url = 'https://api.telegram.org/bot' + TELEGRAM_TOKEN + '/' + metodo
    cuerpo = urllib.parse.urlencode(datos).encode('utf-8')
    peticion = urllib.request.Request(url, data=cuerpo)
    with urllib.request.urlopen(peticion, timeout=10) as r:
        return r.read().decode('utf-8')


def enviar_telegram(chat_id, dispositivo, empresa, lectura, foto):
    if not TELEGRAM_TOKEN or not chat_id:
        print('Sin token o sin chat_id; no se envia Telegram')
        return

    texto = (
        'ALERTA DE CORROSION\n\n'
        'Dispositivo: ' + str(dispositivo.get('nombre', '')) + '\n'
        'Identificador: ' + str(lectura.get('panel_id', '')) + '\n'
        'Empresa: ' + str(empresa.get('nombre', '')) + '\n'
        'Ubicacion: ' + str(dispositivo.get('ubicacion_texto', '-')) + '\n'
        'Fecha: ' + str(lectura.get('timestamp', '')) + '\n\n'
        'Este panel no presentaba corrosion en el reporte anterior.'
    )

    try:
        if foto:
            # Telegram descarga la imagen y la publica en el chat.
            telegram('sendPhoto', {'chat_id': chat_id, 'photo': foto, 'caption': texto})
        else:
            telegram('sendMessage', {'chat_id': chat_id, 'text': texto})
        print('Telegram enviado a', chat_id)
    except Exception as e:
        print('Fallo el envio por Telegram:', e)


def lambda_handler(event, context):
    alertas = 0

    for registro in event.get('Records', []):
        if registro.get('eventName') != 'INSERT':
            continue

        imagen = registro.get('dynamodb', {}).get('NewImage')
        if not imagen:
            continue

        lectura = desde_stream(imagen)

        if lectura.get('prediccion') != 'con_corrosion':
            continue

        panel_id = lectura.get('panel_id')
        if not panel_id:
            continue

        if not es_cambio_de_estado(panel_id):
            print('El panel', panel_id, 'ya venia corroido; no se alerta de nuevo')
            continue

        dispositivo = tabla_dispositivos.get_item(Key={'panel_id': panel_id}).get('Item')
        if not dispositivo:
            print('El panel', panel_id, 'no esta registrado como dispositivo; no se alerta')
            continue

        empresa_id = dispositivo.get('empresa_id')
        empresa = {}
        if empresa_id:
            empresa = tabla_empresas.get_item(Key={'empresa_id': empresa_id}).get('Item') or {}

        foto = url_imagen(lectura.get('imagen_key'))

        try:
            enviar_correo(empresa.get('emails_alerta') or [], dispositivo, empresa, lectura, foto)
        except Exception as e:
            print('Fallo el envio de correo:', e)

        enviar_telegram(empresa.get('telegram_chat_id'), dispositivo, empresa, lectura, foto)
        alertas += 1

    return {'alertas_enviadas': alertas}
