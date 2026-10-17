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

Como en cualquier otro plugin de KOReader: deja la carpeta `ai_lookup.koplugin`
dentro de la carpeta `plugins` de KOReader (la que está junto a `reader.lua`).
Después reinicia KOReader y, si hace falta, actívalo en
**Herramientas → Gestión de complementos**.

La ruta debe quedar así:

```
.../koreader/plugins/ai_lookup.koplugin/main.lua
```

### Con git (recomendado)

Desde la carpeta `plugins` de KOReader:

```
git clone https://github.com/jpestanasalinas/ai_lookup.koplugin.git
```

### Con ZIP

Descarga el ZIP del repositorio y extrae la carpeta `ai_lookup.koplugin` en
`plugins/`.

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

- La respuesta se obtiene en segundo plano (en un subproceso), así que la
  interfaz sigue respondiendo y puedes cancelar la consulta tocando la pantalla
  mientras aparece «Consulting the AI…».
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
├── configuration.lua.sample   # configuración opcional (copiar a configuration.lua)
└── README.md
```
