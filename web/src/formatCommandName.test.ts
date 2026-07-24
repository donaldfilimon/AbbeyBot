import { describe, expect, it } from "vitest";
import { formatCommandName } from "./formatCommandName";

describe("formatCommandName", () => {
  it("prefixes slash-command style names", () => {
    expect(formatCommandName("remember")).toBe("/remember");
    expect(formatCommandName("ask")).toBe("/ask");
  });

  it("leaves persona.* and camelCase internal names unprefixed", () => {
    expect(formatCommandName("persona.abbey")).toBe("persona.abbey");
    expect(formatCommandName("ingestMessage")).toBe("ingestMessage");
  });

  it("keeps an existing leading slash", () => {
    expect(formatCommandName("/voice")).toBe("/voice");
  });
});
