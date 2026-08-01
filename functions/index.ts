import { defineFn } from "@browserbasehq/sdk-functions";
import { chromium } from "playwright-core";
import { z } from "zod";

/* -------------------------------------------------------------------------- */
/*                     Schema definitions & Type aliases                     */
/* -------------------------------------------------------------------------- */
const HNSubmissionSchema = z.object({
  title: z.string().nullable(),
  url: z.string().nullable(),
  rank: z.number().int().positive(),
});
type HNSubmission = z.infer<typeof HNSubmissionSchema>;

const ResponseSchema = z.object({
  message: z.string(),
  // `z.string().datetime()` is deprecated in Zod v26; we accept any ISO string here.
  timestamp: z.string(),
  results: z.array(HNSubmissionSchema),
});
type FunctionResponse = z.infer<typeof ResponseSchema>;

/**
 * Helper: safely parse the MAX_STORIES env var.
 * Falls back to 3 and caps the value to a reasonable maximum (20) to avoid
 * abusing the target site and to keep execution time low.
 */
function getMaxStories(): number {
  const raw = Number(process.env.MAX_STORIES);
  if (Number.isInteger(raw) && raw > 0) {
    return Math.min(raw, 20);
  }
  return 3;
}

/**
 * Helper: extract the top N submissions from Hacker News page.
 * Runs inside `page.evaluate` (browser context).
 */
function extractSubmissions(max: number): {
  title: string | null;
  url: string | null;
  rank: number;
}[] {
  const results: {
    title: string | null;
    url: string | null;
    rank: number;
  }[] = [];

  const nodes = document.querySelectorAll(".athing");
  for (let i = 0; i < Math.min(nodes.length, max); i++) {
    const submission = nodes[i];
    const titleEl = submission.querySelector(".titleline > a");
    if (titleEl) {
      const href = titleEl.getAttribute("href");
      const absoluteUrl = href
        ? new URL(href, "https://news.ycombinator.com").toString()
        : null;
      results.push({
        title: titleEl.textContent ?? null,
        url: absoluteUrl,
        rank: i + 1,
      });
    }
  }
  return results;
}

/* -------------------------------------------------------------------------- */
/*                                   Main                                     */
/* -------------------------------------------------------------------------- */
defineFn(
  "my-function",
  // Using `any` for context to stay compatible with the SDK's exported type.
  async (context: any): Promise<FunctionResponse> => {
    const hasBrowserbaseCreds =
      !!process.env.BROWSERBASE_PROJECT_ID && !!process.env.BROWSERBASE_API_KEY;
    const session = context?.session;

    if (!hasBrowserbaseCreds) {
      console.warn(
        "Browserbase credentials not found. Falling back to a local Chromium instance.",
      );
    }

    // Establish a browser connection, using Browserbase when possible,
    // otherwise launch a local Chromium instance.
    const browserPromise = hasBrowserbaseCreds && session?.connectUrl
      ? Promise.race([
          chromium.connectOverCDP(session.connectUrl),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error("Browser connection timeout")), 15_000),
          ),
        ])
      : chromium.launch({ headless: true });

    const browser = await browserPromise;

    try {
      // In the Browserbase scenario we reuse the first page; for a local launch we create a new context/page.
      const page = hasBrowserbaseCreds
        ? browser.contexts()[0]?.pages()[0]
        : await (await browser.newContext()).newPage();

      if (!page) {
        throw new Error("Unable to obtain a page instance");
      }

      console.log("Navigating to Hacker News...");
      await page.goto("https://news.ycombinator.com", {
        waitUntil: "domcontentloaded",
        timeout: 20_000,
      });

      await page.waitForSelector(".athing", { timeout: 30_000 });

      const maxStories = getMaxStories();

      // Pull raw data from the page.
      const rawData = await page.evaluate(extractSubmissions, maxStories);

      // Validate the extracted payload.
      const parsed = z.array(HNSubmissionSchema).safeParse(rawData);
      if (!parsed.success) {
        console.error("Schema validation failed:", parsed.error);
        throw new Error("Unexpected data format from Hacker News");
      }
      const submissions: HNSubmission[] = parsed.data;

      console.log(`Extracted ${submissions.length} submissions`);

      const response: FunctionResponse = {
        message: "Successfully fetched top Hacker News stories",
        timestamp: new Date().toISOString(),
        results: submissions,
      };

      // Final runtime validation before returning.
      ResponseSchema.parse(response);
      return response;
    } catch (error) {
      console.error("Function execution error:", error);
      throw error;
    } finally {
      // Ensure the remote or local browser is always terminated.
      try {
        await browser.close();
      } catch (closeErr) {
        console.warn("Failed to close browser cleanly:", closeErr);
      }
    }
  },
);
