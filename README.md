# CorrosEdge · Nube (AWS) y página web

Material de Juan Daniel Pino Corredor para la documentación del proyecto. Todo corre en la cuenta de AWS del proyecto, región **us-east-2 (Ohio)**.

## Contenido de esta carpeta

| Carpeta o archivo | Qué es |
|---|---|
| `1-nube/lambdas/` | Código de las 8 funciones Lambda (Python, un archivo `lambda_function.py` por función) |
| `1-nube/despliegue/` | Scripts de PowerShell con los que se desplegó y actualizó todo |
| `1-nube/permisos-iam/` | Permisos de mínimo privilegio de cada función (un rol de IAM por Lambda) |
| `1-nube/presupuesto/` | Configuración del presupuesto de 5 USD y sus avisos |
| `1-nube/Proyeccion_costos_AWS_CorrosEdge.xlsx` | Proyección de costos sin capa gratuita, con los precios usados para cada servicio |
| `2-pagina-web/` | La página completa: `dashboard-v2.html`, los 3 logos y las fotos del modo de demostración |

No se incluyen las claves de los dispositivos, el token de Telegram, las credenciales de AWS ni los datos de contacto de las alertas. El número de la cuenta de AWS se reemplazó por `<ID_CUENTA_AWS>` en los scripts y en los permisos de IAM: para usarlos hay que poner el de la cuenta propia.

## 1. Nube

### Las 8 funciones Lambda

| Función en AWS | Carpeta | Qué hace | Se activa con |
|---|---|---|---|
| authorizer-corrosion | `lambda-authorizer` | Valida la clave `x-api-key` del dispositivo y la asocia a su panel | Antes de cada ruta del dispositivo |
| obtener-config-dispositivo | `lambda-obtener-config` | Entrega frecuencia, hora de inicio y estado activo | `GET /config` |
| generar-url-subida | `lambda-generar-url` | Firma la subida de la foto a S3 (5 min) | `POST /upload-url` |
| guardar-resultado-corrosion | `lambda-guardar-resultado` | Guarda la lectura (veredicto y condición de la lámina) | `POST /resultado` |
| listar-dispositivos | `lambda-listar-dispositivos` | Dispositivos visibles con su última lectura | `GET /dispositivos` |
| obtener-historial-corrosion | `lambda-obtener-historial` | Historial de un panel según rol y empresa | `GET /historial` |
| actualizar-dispositivo | `lambda-actualizar-dispositivo` | Guarda la configuración de un dispositivo | `POST /dispositivo` |
| enviar-alerta | `lambda-enviar-alerta` | Telegram y correo cuando un panel pasa a corroído | DynamoDB Streams |

Variables de entorno (los valores no se incluyen): `DEVICE_KEYS` (huellas SHA-256 de las claves por panel) y `API_SECRET` (clave compartida, en retiro) en el autorizador; `TELEGRAM_TOKEN`, `REMITENTE` y `DASHBOARD_URL` en enviar-alerta.

### Cómo se despliegan

Todo se hizo con la **AWS CLI** desde PowerShell, en Windows. Cada script revisa el estado antes de cambiar algo y se detiene si no coincide. Se ejecutan desde la carpeta `despliegue` así:

```
powershell -ExecutionPolicy Bypass -File .\nombre-del-script.ps1
```

Pasos generales para una función:

1. Empaquetar el código: `Compress-Archive lambda_function.py function.zip`
2. Crearla la primera vez: `aws lambda create-function --function-name <nombre> --runtime python3.x --role <rol> --handler lambda_function.lambda_handler --zip-file fileb://function.zip --region us-east-2`
3. Actualizarla después: `aws lambda update-function-code --function-name <nombre> --zip-file fileb://function.zip`
4. Conectarla a una ruta de API Gateway (HTTP API `97i50k7oag`) con su autorizador.

| Script | Para qué se usó |
|---|---|
| `desplegar-config.ps1` | Crea la Lambda obtener-config-dispositivo y la ruta `GET /config` |
| `desplegar-claves.ps1` | Pasa de una clave compartida a una clave por dispositivo |
| `desplegar-roles.ps1` | Asigna un rol de IAM propio a cada Lambda (y `revertir-roles.ps1` lo deshace) |
| `desplegar-horario.ps1` | Sube las Lambdas de la hora de inicio y publica el dashboard |
| `desplegar-condicion.ps1` | Sube guardar-resultado con el campo de incisión y publica el dashboard |
| `desplegar-dashboard.ps1` | Publica la página web (ver sección 2) |
| `limpieza.ps1` | Limpieza final: panel de prueba, rol viejo, presupuesto de costos |
| `quitar-clave-vieja.ps1` | Borra la clave compartida cuando ningún dispositivo la use |
| `probar-config.ps1` | Prueba `GET /config` con una clave |

### Costos

La hoja `Proyeccion_costos_AWS_CorrosEdge.xlsx` tiene cuatro pestañas: **Supuestos** (editables, en azul), **Precios** (precio de lista de cada servicio, con su fuente), **Proyección** (costo mensual por servicio) y **Para calculator.aws** (los valores para replicarlo en la calculadora oficial).

| Escenario | Paneles | Costo mensual (mes 12, sin capa gratuita) |
|---|---|---|
| Actual | 2 | ≈ 0,10 USD |
| Piloto | 50 | ≈ 1,20 USD |
| Producción | 500 | ≈ 11,40 USD |

Gasto real de octubre de 2026: 0,00 USD. Presupuesto `corrosedge-mensual`: 5 USD al mes sin contar créditos, con avisos por correo al 50 % y al 100 % del gasto real y por pronóstico.

## 2. Página web

### Archivos

Es una sola página estática: `dashboard-v2.html` lleva el HTML, los estilos (CSS) y el código (JavaScript) en el mismo archivo. Además usa `corrosedge-logo.png`, `corrosedge-logo-claro.png` y `corrosedge-icono.png`, y la carpeta `demo/`.

### Librerías

| Uso | Librería | Versión | Se carga desde |
|---|---|---|---|
| Mapa | Leaflet, con mapas de OpenStreetMap | 1.9.4 | unpkg.com |
| Reporte PDF | jsPDF y jsPDF-AutoTable (tablas) | 2.5.1 y 3.8.2 | cdnjs.cloudflare.com |
| Excel | ExcelJS | 4.4.0 | cdnjs.cloudflare.com |
| Tipografías | Saira y Archivo | — | Google Fonts |

Las librerías de PDF y Excel solo se descargan cuando alguien pide el archivo.

### Conexión con la API y con Cognito

Al inicio del código JavaScript (no son secretos: cualquiera que abra la página los ve):

```
API            = https://97i50k7oag.execute-api.us-east-2.amazonaws.com
COGNITO_REGION = us-east-2
CLIENT_ID      = 5h9ts8j46aj5u2on9udoaf0t6a   (cliente de aplicación de Cognito, sin secreto)
```

El inicio de sesión llama directamente a Cognito (`USER_PASSWORD_AUTH`), guarda el token en `sessionStorage` y lo renueva con `REFRESH_TOKEN_AUTH` antes de que venza. Cada consulta a la API envía ese token.

### Cómo se publica y dirección pública

`despliegue/desplegar-dashboard.ps1` sube la página, los logos y las fotos de demostración al bucket S3 `dashboard-corrosion-juanp` y limpia la caché de la distribución de CloudFront `EQPQDJ72IZ4IX`. El bucket es privado: solo CloudFront puede leerlo.

Dirección pública: **https://d35c0bpdfopbh3.cloudfront.net**

### Modo de demostración

- Fotos: `2-pagina-web/demo/prueba-01.jpg` a `prueba-12.jpg` (las 12 pruebas de laboratorio, reducidas a 1280 × 960). En línea quedan en `https://d35c0bpdfopbh3.cloudfront.net/demo/`.
- Datos: están dentro de `dashboard-v2.html`, en la función `construirDemo()` (sección «modo demostración» del código). Arma dos láminas (A con incisión y B sin incisión) con fechas relativas al día en que se abre, y la función `demoRespuesta()` responde en lugar de la API. No consulta AWS ni escribe datos.
- Si no hay internet, abrir `dashboard-v2.html` directamente desde la carpeta también funciona en modo demostración, salvo el mapa.

## Capturas opcionales de la consola de AWS

Estas las toma Juan desde la consola (no están en esta carpeta):

1. Billing and Cost Management → Bills → octubre de 2026 (0,00 USD).
2. Billing → Budgets → `corrosedge-mensual` con sus alertas.
3. Lambda → Functions (las 8 funciones).
4. DynamoDB → Tables (las 4 tablas).
