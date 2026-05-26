# Session Tools

This folder lets this session add extra tools without changing global config.

Create .ts or .js files in this folder. Each file may export a default tool, or named tools.
Tools can use the same plugin tool shape as config tools, or a dependency-free JSON Schema shape.

Example weather.ts:

```ts
import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Return a demo weather report for a city.",
  args: {
    city: tool.schema.string().describe("City name"),
  },
  async execute(args) {
    return "Weather for " + args.city + ": sunny and 25C"
  },
})
```

File names become tool ids. For example, weather.ts default export becomes weather. A named export named forecast in weather.ts becomes weather_forecast.

Session tools are loaded only for this session. They do not replace built-in, MCP, or structured output tools; conflicting ids are skipped.

Dependency-free example:

```ts
export default {
  description: "Echo a short message.",
  args: {
    type: "object",
    properties: {
      message: { type: "string", description: "Message to echo." },
    },
    required: ["message"],
    additionalProperties: false,
  },
  async execute(args, ctx) {
    return {
      title: "Echo",
      output: args.message,
      metadata: { sessionID: ctx.sessionID },
    }
  },
}
```
