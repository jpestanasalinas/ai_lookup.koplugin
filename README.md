# AI Lookup para KOReader

Plugin de KOReader que, al seleccionar una palabra o frase mientras lees,
consulta a un modelo de IA gratuito su **significado general** y su
**significado dentro del contexto** (el párrafo donde aparece).

Al seleccionar texto aparece un botón **AI Lookup** en el menú de resaltado.
Al pulsarlo, el plugin envía a la IA:

- la palabra o frase seleccionada,
- las palabras que la rodean (`Context words`, por defecto 40 antes y 40 después),
- el título y autor del libro (si el EPUB los incluye),
- el idioma en el que quieres la respuesta.

Y muestra la respuesta en un visor desplazable.

Usa por defecto **Groq**, que es gratuito, no pide tarjeta y solo necesita pegar
una API key. También sirve cualquier proveedor con API compatible con OpenAI
(Gemini, OpenRouter, etc.), cambiando el endpoint y el modelo.

## Instalación

1. Copia la carpeta `ai_lookup.koplugin` entera dentro de la carpeta `plugins`
   de KOReader:

   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - PocketBook: `applications/koreader/plugins/`
   - Android: `koreader/plugins/`

   La ruta debe quedar como `.../plugins/ai_lookup.koplugin/main.lua`.

2. Reinicia KOReader.
3. Si hace falta, actívalo en **Herramientas → Gestión de complementos**.

## Configuración (la forma más simple)

1. Crea una cuenta gratuita en <https://console.groq.com> y genera una API key
   en <https://console.groq.com/keys>.
2. En KOReader, abre el menú **Buscar → AI Lookup settings** y pulsa
   **Set API key** para pegarla.
3. Listo. Mantén los valores por defecto de modelo y endpoint.

Opcionalmente, desde el mismo menú puedes cambiar:

- **Model**: por defecto `llama-3.3-70b-versatile`.
- **API endpoint**: por defecto el de Groq.
- **Answer language**: por defecto `Spanish`.
- **Context words**: cuántas palabras de contexto se envían (por defecto 40).

### Alternativa: archivo de configuración

Si prefieres un archivo, renombra `configuration.lua.sample` a
`configuration.lua` y rellena los valores. Los ajustes guardados desde el menú
tienen prioridad sobre este archivo.

## Uso

1. Abre un libro.
2. Selecciona una palabra: mantén pulsado sobre ella (si tienes activado
   «Diccionario con selección de una palabra», tendrás que arrastrar un poco).
3. En el menú que aparece pulsa **AI Lookup**.
4. Espera unos segundos: verás la respuesta. Puedes copiarla con **Copy**.

## Otros proveedores gratuitos (compatible con OpenAI)

- **Google Gemini** (nivel gratuito):
  - endpoint: `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions`
  - modelo: `gemini-2.0-flash`
  - API key gratis en <https://aistudio.google.com/apikey>
- **OpenRouter** (modelos `:free`):
  - endpoint: `https://openrouter.ai/api/v1/chat/completions`
  - modelo: uno que termine en `:free`, p. ej. `deepseek/deepseek-chat-v3-0324:free`
  - API key en <https://openrouter.ai/keys>

Cambia el endpoint y el modelo en **AI Lookup settings**, y usa la API key del
proveedor correspondiente.

## Notas

- En Kindle, Kobo y PocketBook la respuesta se obtiene en segundo plano, así
  que puedes cancelarla tocando la pantalla mientras aparece «Consulting the
  AI…».
- En **Android** la consulta se hace en primer plano (sin crear un subproceso)
  para evitar un problema conocido de KOReader al usar `fork()`. Durante esos
  segundos la interfaz muestra «Consulting the AI…» y no responde a toques.
- Compatible con Kindle, Kobo, PocketBook y Android.
- La API key se guarda en el dispositivo, en `settings/ai_lookup.lua`.
  No la compartas.
- Este plugin envía tu selección y su contexto a un servicio externo. Tenlo en
  cuenta si lees contenido sensible.

## Estructura

```
ai_lookup.koplugin/
├── _meta.lua                  # metadatos del plugin
├── main.lua                   # lógica del plugin
└── configuration.lua.sample   # configuración opcional (copiar a configuration.lua)
```
