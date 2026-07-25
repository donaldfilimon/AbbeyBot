import { defineFn } from "@browserbasehq/sdk-functions";
import { chromium } from "playwright-core";

type HNSubmission = {
  title: string | null;
  url: string | null;
  rank: number;
};

defineFn("my-function", async (context) => {
  const { session } = context;

  console.log("Connecting to browser session:", session.id);

  const browser = await chromium.connectOverCDP(session.connectUrl);
  const browserContext = browser.contexts()[0]!;
  const page = browserContext.pages()[0]!;

  console.log("Navigating to Hacker News...");
  await page.goto("https://news.ycombinator.com");

  await page.waitForSelector(".athing", { timeout: 30000 });

  const titles = await page.evaluate(() => {
    const results: HNSubmission[] = [];

    document.querySelectorAll(".athing").forEach((submission, idx) => {
      if (idx >= 3) return;

      const titleElement = submission.querySelector(".titleline > a");

      if (titleElement) {
        results.push({
          title: titleElement.textContent ?? null,
          url: titleElement.getAttribute("href"),
          rank: idx + 1,
        });
      }
    });

    return results;
  });

  console.log(`Successfully extracted ${titles.length} titles`);

  return {
    message: "Successfully fetched top Hacker News stories",
    timestamp: new Date().toISOString(),
    results: titles,
  };
});
