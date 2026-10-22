# SRI Robot Monitor

App nativa de macOS para **supervisar en tiempo real** el robot [sri-txt-robot](https://github.com/julioserpone/sri-txt-robot) que corre como imagen de contenedor en AWS Lambda.

Parecida en espíritu a *Laravel Herd*: se instala, se configura una vez, y desde ahí vives con la app abierta. Muestra el estado del robot con un LED, trae los logs de CloudWatch en vivo, avisa cuando una ejecución falla y relanza el perfil caliente sin tocar la consola de AWS.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![Licencia MIT](https://img.shields.io/badge/licencia-MIT-green)

---

## Qué hace

| Función | Cómo |
|---|---|
| **LED de estado** | Verde operativo · naranja con advertencias · rojo con errores o sin conexión · azul mientras ejecuta. Nunca depende solo del color: lleva símbolo, texto y etiqueta de accesibilidad. |
| **Logs en vivo** | `StartLiveTail` de CloudWatch Logs empuja cada línea al instante. Si la cuenta o el usuario IAM no lo permite, la app sondea con `FilterLogEvents` y te dice por qué. |
| **Relanzar el robot** | Invoca la imagen publicada con el perfil caliente. Modo `event` (dispara y sigue) o modo `tail` (espera el resumen con descargas, claves y fallos). |
| **Alertas** | Notificaciones de macOS al terminar con errores, con advertencias o si se pierde la supervisión. |
| **Credenciales** | Asistente de primera instalación y pantalla de revalidación. Las claves viven en el Llavero, nunca en un JSON. |
| **Claves del robot** | Clave del portal y de anti-captcha guardadas en el Llavero y enviadas en el evento (modo `tail`), sin reconfigurar la función. |
| **Descargar TXT y JSON** | Localiza en S3 los archivos de cada ejecución y los guarda con el panel de macOS. |
| **Todo dentro de la app** | Preferencias, historial, logs y caché en el contenedor de la app. Botones para abrir la carpeta y para restablecerla. |

## Requisitos

- macOS 14 (Sonoma) o superior. La interfaz usa *Liquid Glass* de macOS 26 cuando está disponible.
- Una función de Lambda con la imagen de `sri-txt-robot` desplegada.
- Un usuario IAM con permisos mínimos:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity",
        "lambda:GetFunctionConfiguration",
        "lambda:InvokeFunction",
        "logs:FilterLogEvents",
        "logs:StartLiveTail",
        "s3:ListBucket",
        "s3:GetObject"
      ],
      "Resource": "*"
    }
  ]
}
```

`logs:StartLiveTail` es opcional: sin ese permiso la app funciona con sondeo y lo indica en pantalla. Los permisos de S3 solo hacen falta para descargar el TXT y el JSON de una ejecución.

## Instalación

### Desde el DMG

1. Descarga el último `SriRobotMonitor.dmg` de [Releases](../../releases).
2. Arrástralo a **Aplicaciones**.
3. Como la build pública no está notarizada, la primera vez abre la app con **clic derecho → Abrir**.

### Desde el código

```bash
git clone https://github.com/julioserpone/sri-robot-monitor.git
cd sri-robot-monitor
open SriRobotMonitor.xcodeproj
```

Compila con `⌘R`. Para pruebas y convenciones, consulta [docs/TESTING.md](docs/TESTING.md).

## Primer uso

1. La app abre el asistente de **primera instalación**.
2. Pega `Access Key ID`, `Secret Access Key` y, si usas credenciales temporales, el *session token*.
3. Pulsa **Probar credenciales**: se valida la identidad con STS.
4. Indica región, función de Lambda y log group.
5. Pulsa **Empezar a supervisar**.

Desde **Ajustes → Claves del robot** puedes guardar la clave del portal y la de anti-captcha. Se envían en el evento cuando relanzas con **Esperar el resultado** activado.

## Descargar el TXT y el JSON

En **Ejecuciones**, abre una ejecución con el LED verde o naranja: al final del detalle aparece *Archivos de la ejecución*. La app busca en el bucket configurado el TXT que el robot descargó del portal y el JSON con las claves, y los guarda donde elijas.

Las rutas que inspecciona son las del robot:

```
facturas-recibidas/{ambiente}/{año}/{mes}/raw/       → TXT del portal
facturas-recibidas/{ambiente}/{año}/{mes}/manifest/  → JSON de claves
```

Necesita `s3:ListBucket` y `s3:GetObject`, el bucket indicado en **Ajustes → Conexión** y el nombre de ambiente (`produccion`, `pruebas`, …) que usa el robot.

## Por qué el LED está naranja o rojo

El detalle de la ejecución lista el texto de cada advertencia y de cada error, con el `RequestId`. El botón *Ver esos WARNING en los registros* abre los logs filtrados por esa ejecución.

## Cómo leer el LED

| Color | Significado |
|---|---|
| 🟢 Verde | La última ejecución terminó sin errores ni advertencias. |
| 🟠 Naranja | Terminó bien pero con advertencias, o la lectura en vivo cayó a sondeo. |
| 🔴 Rojo | Falló la última ejecución, o la app no puede leer CloudWatch. |
| 🔵 Azul | Hay una ejecución en curso. |
| ⚪️ Gris | Todavía no hay datos. |

## Cómo se guardan los datos

```
~/Library/Containers/com.julioserpone.sri-robot-monitor/Data/
├── Library/Application Support/SriRobotMonitor/
│   ├── configuracion.json      # región, función, preferencias (sin secretos)
│   ├── ejecuciones.json        # últimas 100 ejecuciones
│   ├── registros.json          # últimos 2 000 logs
│   ├── notificadas.json        # avisos ya enviados
│   └── onboarding.json         # borrador sin secretos
└── Library/Keychain/           # credenciales AWS y claves del robot
```

El botón **Abrir carpeta** de Ajustes lleva directo a esa ruta. **Restablecer la aplicación** borra el contenedor y la entrada del Llavero.

## Arquitectura

Resumen rápido:

- `SriRobotMonitor/AWS/` — cliente HTTP firmado con SigV4 escrito a mano (STS, Lambda, CloudWatch Logs), incluido el *event stream* de Live Tail. Sin dependencias externas.
- `SriRobotMonitor/Services/` — `MonitorEngine` (estado observable), análisis de ejecuciones a partir de los logs y persistencia.
- `SriRobotMonitor/Views/` — interfaz SwiftUI en cristal líquido.

Detalle en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Documentación

- [CHANGELOG.md](CHANGELOG.md) — histórico de versiones.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — capas, flujos y decisiones.
- [docs/TESTING.md](docs/TESTING.md) — cómo probar sin credenciales reales.
- [docs/AI_USAGE.md](docs/AI_USAGE.md) — cómo se ha usado IA en este proyecto.
- [CONTRIBUTING.md](CONTRIBUTING.md) — convenciones, ramas y PR.
- [SECURITY.md](SECURITY.md) — reporte de vulnerabilidades.

## Licencia

MIT. Ver [LICENSE](LICENSE).
