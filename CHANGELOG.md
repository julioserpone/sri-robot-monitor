# Changelog

Todos los cambios relevantes de este proyecto se documentan aquí.
El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/)
y el versionado [SemVer](https://semver.org/lang/es/).

## [No publicado]

### Pendiente

- Firma y notarización de las builds publicadas.

## [1.2.0] — 2026-10-21

### Añadido

- **Descarga del TXT y el JSON de cada ejecución.** El detalle de una ejecución
  localiza en S3 los archivos que dejó el robot (`raw/` y `manifest/`) y los
  guarda donde elijas con el panel de macOS. Requiere `s3:GetObject` y
  `s3:ListBucket`, y el bucket configurado en Ajustes.
- **Advertencias explicadas.** El detalle de la ejecución muestra el texto de
  cada `WARNING` (antes solo se contaba), con un atajo para verlos en
  Registros filtrados por `RequestId`. El dashboard también los muestra.
- Campo de bucket S3 y de ambiente en Ajustes, y botón que abre los registros
  de una ejecución concreta.
- Pruebas aisladas del cliente S3 con `URLProtocol`, y de las advertencias.

### Cambiado

- **Botones del onboarding unificados.** «Atrás», «Probar credenciales»,
  «Comprobar función» y «Continuar» comparten componente, altura y formato.
- **Texto del LED en la bienvenida** ahora explica para qué sirve (saber en qué
  etapa está el robot) en lugar de enumerar colores.
- La documentación usa nombres de archivo en inglés (`ARCHITECTURE.md`,
  `TESTING.md`, `AI_USAGE.md`) con el contenido en español.

### Corregido

- **Rebote y parpadeo del formulario de credenciales.** Cada tecla reescribía
  el borrador completo y reiniciaba los otros pasos; ahora solo se invalida lo
  necesario. Revelar el secreto ya no destruye el campo ni pierde el foco.
- **El LED de la barra de menús no se pintaba:** macOS lo trataba como imagen
  plantilla y descartaba el color.
- **Rutas con espacios o tildes** se firmaban distintas a las enviadas, lo que
  habría fallado al descargar archivos con nombres reales.
- `ejecuciones.json` de versiones anteriores se descartaba al añadir
  `warningMessages`; ahora se lee con tolerancia.

## [1.1.0] — 2026-10-21

### Añadido

- **Live Tail**: los logs llegan por `StartLiveTail` de CloudWatch Logs, con
  reconexión automática y vuelta a `FilterLogEvents` si la cuenta no lo admite.
- **Modo `tail` al relanzar**: opción *Esperar el resultado* que mantiene la
  conexión hasta el resumen de la ejecución y muestra descargas, claves y fallos.
- **Claves del robot en Ajustes**: clave del portal (`SRI_PASSWORD`) y de
  anti-captcha (`ANTICAPTCHA_API_KEY`), guardadas en el Llavero y enviadas en el
  evento, sin reconfigurar la función.
- **Directorio de perfil opcional** (`SRI_PERFIL_DIR`) para imágenes con varias
  rutas de perfil.
- **`StatusLED` accesible**: símbolo, texto, etiqueta de accesibilidad y
  respeto por *reduce motion*.
- **Indicador del medio de lectura** en la barra lateral y en Ajustes
  (Live Tail ⇄ sondeo) con el motivo del respaldo.
- **Avisos de supervisión interrumpida**: notificación cuando es la propia app
  la que deja de poder leer AWS.
- **Botón para revalidar todo el juego de credenciales** desde el menú de la
  barra de estado.
- **Mensajes de error de AWS traducidos** a causa y acción recomendada.
- Workflows de CI (higiene, build, tests, CodeQL) y de Release (DMG).
- Documentación de arquitectura, pruebas, uso de IA y convenciones de GitHub.

### Cambiado

- El LED refleja también fallos de supervisión, no solo el resultado de la
  última ejecución.
- `MonitorEngine` acepta un `URLSession` inyectable, lo que permite probar los
  clientes de AWS sin red.
- La persistencia crea su carpeta al arrancar y tolera JSON escritos por
  versiones anteriores.
- `KeychainStore` guarda credenciales y secretos del robot en una sola entrada.

### Corregido

- El decodificador del *event stream* de AWS no recortaba el separador
  `\r\n\r\n` entre mensajes y no validaba el CRC-32 del preludio, lo que podía
  desalinear el flujo.
- El análisis de ejecuciones marcaba como error las que terminaban sin `REPORT`
  por un reinicio de la plataforma.
- La app podía mostrar "sin datos" cuando en realidad había un error de
  conexión.

## [1.0.0] — 2026-10-20

### Añadido

- Versión inicial: LED de estado, historial de ejecuciones, logs,
  onboarding de AWS, revalidación de credenciales, notificaciones y relanzado
  del perfil caliente.
