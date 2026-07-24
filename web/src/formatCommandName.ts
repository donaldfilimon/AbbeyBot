/** Mirror of AbbeyCore `InteractionCommandLabel.format` for SPA tables. */
export function formatCommandName(name: string): string {
  const trimmed = name.trim();
  if (!trimmed) return trimmed;
  if (trimmed.startsWith("/")) return trimmed;
  if (trimmed.startsWith("persona.")) return trimmed;
  if (trimmed.includes(".")) return trimmed;
  if (/[A-Z]/.test(trimmed)) return trimmed;
  return `/${trimmed}`;
}
