import { useEffect, useRef, useState } from 'react';
import { t } from '@apnacircle/i18n';
import { prepareFeedbackScreenshot } from '../lib/prepare-feedback-screenshot.js';
import { FEEDBACK_CATEGORIES, feedbackSubmissionSchema, type FeedbackCategory } from '@apnacircle/types';

declare global {
  interface Window {
    turnstile?: {
      render: (
        container: HTMLElement,
        options: {
          sitekey: string;
          callback: (token: string) => void;
          'expired-callback'?: () => void;
          'error-callback'?: () => void;
        },
      ) => string;
      reset: (widgetId?: string) => void;
    };
  }
}

export interface FeedbackFormProps {
  turnstileSiteKey: string;
}

const CATEGORY_LABELS: Record<FeedbackCategory, string> = {
  bug: t('feedback.category.bug'),
  feature_request: t('feedback.category.feature_request'),
  suggestion: t('feedback.category.suggestion'),
  content_correction: t('feedback.category.content_correction'),
  other: t('feedback.category.other'),
};

export function FeedbackForm({ turnstileSiteKey }: FeedbackFormProps) {
  const [category, setCategory] = useState<FeedbackCategory>('suggestion');
  const [subject, setSubject] = useState('');
  const [description, setDescription] = useState('');
  const [replyEmail, setReplyEmail] = useState('');
  const [turnstileToken, setTurnstileToken] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [referenceId, setReferenceId] = useState<string | null>(null);

  const screenshotInput = useRef<HTMLInputElement>(null);
  const widgetContainerRef = useRef<HTMLDivElement | null>(null);
  const widgetIdRef = useRef<string | undefined>(undefined);

  useEffect(() => {
    let active = true;

    const mountWidget = () => {
      if (!active || !widgetContainerRef.current || !window.turnstile) return;
      if (widgetIdRef.current !== undefined) return;
      widgetIdRef.current = window.turnstile.render(widgetContainerRef.current, {
        sitekey: turnstileSiteKey,
        callback: (token) => setTurnstileToken(token),
        'expired-callback': () => setTurnstileToken(''),
        'error-callback': () => setTurnstileToken(''),
      });
    };

    if (window.turnstile) {
      mountWidget();
    } else {
      const existingScript = document.querySelector<HTMLScriptElement>(
        'script[data-turnstile-api="true"]',
      );
      if (existingScript) {
        existingScript.addEventListener('load', mountWidget);
      } else {
        const script = document.createElement('script');
        script.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
        script.async = true;
        script.defer = true;
        script.dataset.turnstileApi = 'true';
        script.addEventListener('load', mountWidget);
        document.head.appendChild(script);
      }
    }

    return () => {
      active = false;
    };
  }, [turnstileSiteKey]);

  async function handleSubmit(event: React.SyntheticEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrorMessage(null);

    const candidate = {
      category,
      subject,
      description,
      replyEmail,
      turnstileToken,
    };

    const parsed = feedbackSubmissionSchema.safeParse(candidate);
    if (!parsed.success) {
      const firstIssue = parsed.error.issues[0]?.message ?? t('feedback.errorGeneric');
      setErrorMessage(
        parsed.error.issues.some((i) => i.path[0] === 'turnstileToken')
          ? t('feedback.errorTurnstile')
          : firstIssue,
      );
      return;
    }

    setSubmitting(true);
    try {
      const file = screenshotInput.current?.files?.item(0);
      let body: BodyInit = JSON.stringify(parsed.data);
      const headers = new Headers({ 'content-type': 'application/json' });
      if (file) {
        let screenshot: Blob;
        try {
          screenshot = await prepareFeedbackScreenshot(file);
        } catch {
          setErrorMessage(t('feedback.screenshotInvalid'));
          return;
        }
        const parts = new FormData();
        parts.append('payload', body);
        parts.append('screenshot', screenshot, 'feedback.jpg');
        body = parts;
        headers.delete('content-type');
      }
      const response = await fetch('/api/feedback', { method: 'POST', headers, body });

      if (response.status === 429) {
        setErrorMessage(t('feedback.errorRateLimit'));
        return;
      }

      const payload = (await response.json()) as {
        ok?: boolean;
        referenceId?: string;
        error?: string;
      };

      if (!response.ok || !payload.ok || !payload.referenceId) {
        if (payload.error === 'turnstile_failed') {
          setErrorMessage(t('feedback.errorTurnstile'));
        } else if (payload.error === 'invalid_screenshot') {
          setErrorMessage(t('feedback.screenshotInvalid'));
        } else {
          setErrorMessage(t('feedback.errorGeneric'));
        }
        window.turnstile?.reset(widgetIdRef.current);
        setTurnstileToken('');
        return;
      }

      setReferenceId(payload.referenceId);
      setSubject('');
      setDescription('');
      setReplyEmail('');
      setTurnstileToken('');
      window.turnstile?.reset(widgetIdRef.current);
    } catch {
      setErrorMessage(t('feedback.errorGeneric'));
    } finally {
      setSubmitting(false);
    }
  }

  if (referenceId) {
    return (
      <div
        role="status"
        className="rounded-2xl border border-[var(--ac-success)]/30 bg-[var(--ac-success-soft)] p-6 text-[var(--ac-success)]"
      >
        <h2 className="text-lg font-bold">{t('feedback.successTitle')}</h2>
        <p className="mt-2 text-sm">{t('feedback.successBody', { id: referenceId })}</p>
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-5" noValidate>
      {errorMessage ? (
        <div
          role="alert"
          className="rounded-xl border border-[var(--ac-danger)]/30 bg-[var(--ac-danger-soft)] p-4 text-sm text-[var(--ac-danger)]"
        >
          {errorMessage}
        </div>
      ) : null}

      <div>
        <label
          htmlFor="feedback-category"
          className="block text-sm font-semibold text-[var(--ac-ink)]"
        >
          {t('feedback.categoryLabel')}
        </label>
        <select
          id="feedback-category"
          name="category"
          value={category}
          onChange={(e) => setCategory(e.target.value as FeedbackCategory)}
          className="mt-1.5 w-full rounded-xl border border-[var(--ac-border-strong)] bg-[var(--ac-surface)] px-3.5 py-2.5 text-sm text-[var(--ac-ink)]"
        >
          {FEEDBACK_CATEGORIES.map((item) => (
            <option key={item} value={item}>
              {CATEGORY_LABELS[item]}
            </option>
          ))}
        </select>
      </div>

      <div>
        <label
          htmlFor="feedback-subject"
          className="block text-sm font-semibold text-[var(--ac-ink)]"
        >
          {t('feedback.subjectLabel')}
        </label>
        <input
          id="feedback-subject"
          name="subject"
          type="text"
          required
          minLength={5}
          maxLength={120}
          value={subject}
          onChange={(e) => setSubject(e.target.value)}
          placeholder={t('feedback.subjectPlaceholder')}
          className="mt-1.5 w-full rounded-xl border border-[var(--ac-border-strong)] bg-[var(--ac-surface)] px-3.5 py-2.5 text-sm text-[var(--ac-ink)]"
        />
      </div>

      <div>
        <label
          htmlFor="feedback-description"
          className="block text-sm font-semibold text-[var(--ac-ink)]"
        >
          {t('feedback.descriptionLabel')}
        </label>
        <textarea
          id="feedback-description"
          name="description"
          required
          rows={5}
          minLength={20}
          maxLength={2000}
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder={t('feedback.descriptionPlaceholder')}
          className="mt-1.5 w-full rounded-xl border border-[var(--ac-border-strong)] bg-[var(--ac-surface)] px-3.5 py-2.5 text-sm text-[var(--ac-ink)]"
        />
      </div>

      <div>
        <label
          htmlFor="feedback-reply-email"
          className="block text-sm font-semibold text-[var(--ac-ink)]"
        >
          {t('feedback.replyEmailLabel')}
        </label>
        <input
          id="feedback-reply-email"
          name="replyEmail"
          type="email"
          maxLength={254}
          value={replyEmail}
          onChange={(e) => setReplyEmail(e.target.value)}
          placeholder={t('feedback.replyEmailPlaceholder')}
          aria-describedby="feedback-reply-hint"
          className="mt-1.5 w-full rounded-xl border border-[var(--ac-border-strong)] bg-[var(--ac-surface)] px-3.5 py-2.5 text-sm text-[var(--ac-ink)]"
        />
        <p id="feedback-reply-hint" className="mt-1 text-xs text-[var(--ac-ink-muted)]">
          {t('feedback.replyEmailHint')}
        </p>
      </div>

      <div>
        <p className="mb-2 text-sm font-semibold text-[var(--ac-ink)]">
          {t('feedback.turnstileLabel')}
        </p>
        <div>
        <label htmlFor="feedback-screenshot" className="block text-sm font-semibold">{t('feedback.screenshot')}</label>
        <input ref={screenshotInput} id="feedback-screenshot" type="file" accept="image/png,image/jpeg,image/webp"
          aria-describedby="feedback-screenshot-help" className="mt-1.5 block max-w-full text-sm" />
        <p id="feedback-screenshot-help" className="mt-1 text-sm text-[var(--ac-ink-muted)]">{t('feedback.screenshotHelp')}</p>
      </div>

      <div ref={widgetContainerRef} className="min-h-[65px]" />
      </div>

      <button
        type="submit"
        disabled={submitting}
        className="inline-flex min-h-11 items-center justify-center rounded-xl bg-[var(--ac-accent)] px-6 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-[var(--ac-accent-hover)] disabled:opacity-60"
      >
        {submitting ? t('feedback.submittingButton') : t('feedback.submitButton')}
      </button>
    </form>
  );
}
