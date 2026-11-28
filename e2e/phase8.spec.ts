import { expect, test, type Page } from '@playwright/test';

const appOrigin = 'http://127.0.0.1:4173';
const googleFixture = 'http://localhost:4173/__test/google';
const observationsPath = '/__test/observations';
const meetupPath = '/saharanpur/meetups/test-city-walk';

test.beforeEach(async ({ context, request }) => {
  await request.post(observationsPath);
  await context.route('**/*', (route) => {
    const url = new URL(route.request().url());
    return url.origin === appOrigin || url.origin + url.pathname === googleFixture
      ? route.continue()
      : route.abort();
  });
});

async function stubTurnstile(page: Page, token: 'fixture-verified' | 'fixture-rejected') {
  await page.route('https://challenges.cloudflare.com/turnstile/v0/api.js?*', (route) =>
    route.fulfill({
      contentType: 'text/javascript',
      body: `window.turnstile = {
        render(container, options) {
          const button = document.createElement('button');
          button.type = 'button';
          button.textContent = 'Complete test verification';
          button.addEventListener('click', () => options.callback(${JSON.stringify(token)}));
          container.append(button);
          return 'test-widget';
        },
        reset() {},
      };`,
    }),
  );
}

async function fillFeedback(page: Page, token: 'fixture-verified' | 'fixture-rejected') {
  await stubTurnstile(page, token);
  await page.goto('/feedback');
  await page.getByRole('button', { name: 'Decline analytics' }).click();
  const challenge = page.getByRole('button', { name: 'Complete test verification' });
  await challenge.waitFor();
  await page.getByRole('combobox', { name: 'Category' }).selectOption('content_correction');
  await page.getByRole('textbox', { name: 'Subject' }).fill('Update the opening hours');
  await page.getByRole('textbox', { name: 'Details' }).fill('The park now opens an hour earlier on Fridays.');
  await page.getByRole('textbox', { name: 'Reply email (optional)' }).fill('visitor@example.invalid');
  await challenge.click();
}

test('Google sign-in returns to People, keeps the session and preserves the member gate', async ({ page }) => {
  await page.goto('/people');
  const header = page.getByRole('banner');
  await expect(header.getByRole('link', { name: 'Sign in', exact: true })).toBeVisible();
  await page.getByRole('main').getByRole('link', { name: 'Sign in with Google' }).click();
  await expect(page).toHaveURL((url) => url.origin + url.pathname === googleFixture);
  await page.getByRole('link', { name: 'Continue as test member' }).click();

  await expect(page).toHaveURL(appOrigin + '/people');
  await expect(page.getByText(/You’re signed in with Google/)).toBeVisible();
  await expect(page.getByRole('link', { name: 'Sign in with Google' })).toHaveCount(0);
  await expect(page.getByText('People directory coming soon')).toBeVisible();

  await page.goto('/');
  await header.getByRole('link', { name: 'Account' }).click();
  await expect(page).toHaveURL(appOrigin + '/me/profile');
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(header.getByRole('link', { name: 'Sign in', exact: true })).toBeVisible();
});

test('cancelled Google sign-in returns to People with a retry message', async ({ page, context }) => {
  await page.goto('/people');
  await page.getByRole('link', { name: 'Sign in with Google' }).click();
  await page.getByRole('link', { name: 'Cancel sign-in' }).click();
  await expect(page).toHaveURL(appOrigin + '/people?signin=failed');
  await expect(page.getByRole('alert')).toHaveText('Google sign-in could not be completed. Please try again.');
  expect((await context.cookies()).some((cookie) => cookie.name === 'ac-member-session')).toBe(false);
});

test('verified feedback is saved and shows the stored reference', async ({ page, request }) => {
  await fillFeedback(page, 'fixture-verified');
  const submitted = page.waitForResponse((response) => new URL(response.url()).pathname === '/api/feedback');
  await page.getByRole('button', { name: 'Submit feedback' }).click();
  expect((await submitted).status()).toBe(201);
  const { feedback, analytics } = await (await request.get(observationsPath)).json();
  expect(feedback).toEqual([{
    id: expect.any(String),
    p_category: 'content_correction',
    p_subject: 'Update the opening hours',
    p_message: 'The park now opens an hour earlier on Fridays.',
    p_contact_email: 'visitor@example.invalid',
  }]);
  expect(analytics).toEqual([]);
  await expect(page.getByRole('status').getByText(`FB-${feedback[0].id.toUpperCase()}`, { exact: false })).toBeVisible();
});

test('failed Turnstile verification leaves feedback unsaved', async ({ page, request }) => {
  await fillFeedback(page, 'fixture-rejected');
  const submitted = page.waitForResponse((response) => new URL(response.url()).pathname === '/api/feedback');
  await page.getByRole('button', { name: 'Submit feedback' }).click();
  expect((await submitted).status()).toBe(400);
  await expect(page.getByRole('alert')).toHaveText('Please complete the verification check before submitting.');
  expect(await (await request.get(observationsPath)).json()).toEqual({ feedback: [], analytics: [] });
});

test('analytics starts only after consent and stops after withdrawal', async ({ page, context, request }) => {
  const readAnalytics = async () => (await (await request.get(observationsPath)).json()).analytics;
  const visitMeetup = async () => {
    const posted = page.waitForResponse((response) => new URL(response.url()).pathname === '/api/analytics/meetup-view');
    await page.goto(meetupPath);
    await expect(page.getByRole('heading', { name: 'Test city walk' })).toBeVisible();
    expect((await posted).status()).toBe(204);
  };

  await visitMeetup();
  await expect(page.getByRole('region', { name: 'Analytics preferences' })).toBeVisible();
  expect(await readAnalytics()).toEqual([]);
  expect((await context.cookies()).some((cookie) => cookie.name === 'ac_consent')).toBe(false);

  const posted = page.waitForResponse((response) => new URL(response.url()).pathname === '/api/analytics/meetup-view');
  await page.getByRole('button', { name: 'Allow analytics' }).click();
  expect((await posted).status()).toBe(204);
  await expect(page.getByRole('region', { name: 'Analytics preferences' })).toHaveCount(0);
  const consent = (await context.cookies()).find((cookie) => cookie.name === 'ac_consent');
  expect(consent).toMatchObject({ httpOnly: true, sameSite: 'Strict', value: expect.stringMatching(/^v1\.[a-f0-9-]{36}$/) });
  const expected = [{
    event: 'meetup_viewed',
    properties: {
      distinct_id: consent?.value.slice(3), $geoip_disable: true, $process_person_profile: false,
    },
  }];
  expect(await readAnalytics()).toEqual(expected);

  await page.goto('/cookies#analytics');
  await expect(page.getByText('Optional analytics are on.', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Decline analytics' }).click();
  await expect(page.getByText('Optional analytics are off.', { exact: true })).toBeVisible();
  expect((await context.cookies()).find((cookie) => cookie.name === 'ac_consent')?.value).toBe('v1.off');
  await visitMeetup();
  expect(await readAnalytics()).toEqual(expected);
});
