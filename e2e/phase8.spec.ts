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

test('People is active in desktop and mobile navigation, and the theme persists', async ({ page, request }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto('/people');
  const header = page.getByRole('banner');
  const nav = header.getByRole('navigation', { name: 'Main navigation' });
  await expect(nav.getByRole('link', { name: 'People' })).toHaveAttribute('aria-current', 'page');
  await expect(nav.getByRole('link', { name: 'Cities' })).not.toHaveAttribute('aria-current', 'page');

  const theme = header.getByRole('combobox', { name: 'Theme' });
  await theme.selectOption('blue');
  await expect(page.locator('body')).toHaveCSS('background-color', 'rgb(240, 245, 251)');
  const favicon = await page.locator('link[rel="icon"]').getAttribute('href');
  expect((await request.get(favicon ?? '/missing')).headers()['content-type']).toContain('image/png');
  await page.goto('/saharanpur/people');
  await expect(nav.getByRole('link', { name: 'People' })).toHaveAttribute('aria-current', 'page');
  await expect(theme).toHaveValue('blue');

  await page.setViewportSize({ width: 390, height: 844 });
  await header.locator('summary[aria-label="Menu"]').press('Enter');
  await expect(nav.getByRole('link', { name: 'People' })).toHaveAttribute('aria-current', 'page');
  await theme.selectOption('pink');
  await expect(page.locator('body')).toHaveCSS('background-color', 'rgb(252, 241, 245)');
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'pink');
});

test('moderators can review and approve feedback with a private decision note', async ({ page, context }) => {
  const inboxPath = '/me/moderation/feedback';
  expect((await page.goto(inboxPath))?.status()).toBe(401);
  await context.addCookies([{ name: 'ac-member-session', value: 'fixture.staff.session', url: appOrigin }]);
  await page.goto(inboxPath);
  await page.getByRole('combobox', { name: 'Review status' }).selectOption('new');
  await page.getByRole('button', { name: 'Apply filter' }).click();
  await page.getByRole('link', { name: /Correct the park opening hours/ }).click();
  await page.getByRole('button', { name: 'Start review' }).click();
  await expect(page.getByText('In review', { exact: true })).toBeVisible();
  await page.getByRole('textbox', { name: 'Internal decision note' }).fill('Opening times checked against the posted hours.');
  await page.getByRole('button', { name: 'Approve feedback' }).click();
  await expect(page.getByText('Approved', { exact: true })).toBeVisible();
  await expect(page.getByText('Opening times checked against the posted hours.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approve feedback' })).toHaveCount(0);
});

test('a member completes onboarding, applies to host, and gets a first meetup reviewed', async ({ page, context, browser }) => {
  await context.addCookies([{ name: 'ac-member-session', value: 'fixture.member.session', url: appOrigin }]);
  await page.route('https://challenges.cloudflare.com/turnstile/v0/api.js', (route) => route.fulfill({
    contentType: 'text/javascript',
    body: `const field = document.createElement('input'); field.type = 'hidden';
      field.name = 'cf-turnstile-response'; field.value = 'fixture-verified';
      document.querySelector('.cf-turnstile').append(field);`,
  }));
  await page.goto('/me/profile');
  await expect(page.getByText('Google test person')).toBeVisible();
  await expect(page.getByText('google-member@example.invalid')).toBeVisible();
  await expect.poll(() => page.locator('img[src="/me/profile/google-avatar"]').evaluate((image: HTMLImageElement) => image.naturalWidth)).toBe(48);
  await page.getByRole('link', { name: 'Complete member onboarding' }).click();
  await page.locator('input[name="cf-turnstile-response"]').waitFor({ state: 'attached' });
  await page.getByLabel('Display name').fill('Test member');
  await page.getByLabel('Date of birth').fill('1995-01-01');
  await page.getByLabel('I accept the Terms and acknowledge the Privacy Notice.').check();
  await page.getByLabel('I agree to follow the Community Guidelines.').check();
  await page.getByRole('button', { name: 'Create member profile' }).click();
  await expect(page).toHaveURL(appOrigin + '/me/profile');

  await page.getByRole('link', { name: 'Host dashboard' }).click();
  await page.getByLabel('About you and what you plan to host').fill('I organise casual public walks with a small local group.');
  await page.getByLabel('I accept the Host Guidelines and Agreement.').check();
  await page.getByRole('button', { name: 'Submit host application' }).click();
  await expect(page.getByText('Your application is awaiting administrator review.')).toBeVisible();

  const admin = await browser.newContext();
  try {
    await admin.addCookies([{ name: 'ac-member-session', value: 'fixture.admin.session', url: appOrigin }]);
    const review = await admin.newPage();
    await review.goto(appOrigin + '/me/admin/review');
    await review.getByLabel('How you vetted the host').selectOption('video_call');
    await review.getByLabel('Review note').fill('Called the applicant and checked the local reference.');
    await review.getByRole('button', { name: 'Approve', exact: true }).click();
    await expect(review.getByText('Review saved.')).toBeVisible();

    await page.reload();
    await page.getByRole('link', { name: 'Create meetup' }).click();
    const day = new Date(Date.now() + 172_800_000).toISOString().slice(0, 10);
    await page.getByLabel('Meetup title').fill('Sunday group walk');
    await page.getByLabel('Details').fill('Meet our group for a short walk through the public garden.');
    await page.getByLabel('Public venue name').fill('Company Garden');
    await page.getByLabel('Locality').fill('Civil Lines');
    await page.getByLabel('Starts (India Standard Time)').fill(day + 'T10:00');
    await page.getByLabel('Ends (India Standard Time)').fill(day + 'T12:00');
    await page.getByLabel('I confirm the venue is a public place.').check();
    await page.getByRole('button', { name: 'Submit meetup' }).click();
    await expect(page.getByText(/Awaiting admin review/)).toBeVisible();

    await review.reload();
    await expect(review.getByRole('heading', { name: 'Sunday group walk' })).toBeVisible();
    await review.getByLabel('Review note').fill('The public venue, time, and event details have been checked.');
    await review.getByRole('button', { name: 'Approve', exact: true }).click();
    await expect(review.getByText('Review saved.')).toBeVisible();
    await page.reload();
    await expect(page.getByText(/Published/, { exact: false })).toBeVisible();
  } finally {
    await admin.close();
  }
});

test('a moderator enrolls an authenticator and returns to the feedback inbox', async ({ page, context }) => {
  await context.addCookies([{ name: 'ac-member-session', value: 'fixture.staff-unverified.session', url: appOrigin }]);
  await page.goto('/me/moderation/feedback');
  await page.getByRole('link', { name: 'Verify with your authenticator' }).click();
  await page.getByRole('button', { name: 'Set up authenticator' }).click();
  await expect(page.getByText(/using the setup key below/)).toBeVisible();
  await page.getByLabel('Six-digit code').fill('123456');
  await page.getByRole('button', { name: 'Verify code' }).click();
  await expect(page).toHaveURL(appOrigin + '/me/moderation/feedback');
  await expect(page.getByRole('heading', { name: 'Feedback inbox' })).toBeVisible();
  await expect(page.getByText('Correct the park opening hours')).toBeVisible();
});

test('place cards use readable text in all palettes when the browser prefers dark mode', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto('/');
  const heading = page.getByRole('heading', { name: 'Ambedkar Park' });
  const theme = page.getByRole('combobox', { name: 'Theme' });
  for (const [name, color] of [
    ['sage', 'rgb(35, 55, 47)'], ['blue', 'rgb(35, 53, 79)'], ['pink', 'rgb(69, 45, 57)'],
  ]) {
    await theme.selectOption(name!);
    await expect(heading).toHaveCSS('color', color!);
  }
});
