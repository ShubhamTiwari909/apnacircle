import { describe, expect, it } from 'vitest';
import { feedbackSubmissionSchema } from './feedback.js';

describe('feedbackSubmissionSchema', () => {
  it('accepts valid feedback payload without optional reply email', () => {
    const parsed = feedbackSubmissionSchema.safeParse({
      category: 'content_correction',
      subject: 'Update timing note for Company Garden',
      description: 'Visited this morning and noticed the main gate entry hours changed slightly.',
      replyEmail: '',
      turnstileToken: 'test-token-123',
    });

    expect(parsed.success).toBe(true);
  });

  it('rejects missing Turnstile token or overly short description', () => {
    const parsed = feedbackSubmissionSchema.safeParse({
      category: 'bug',
      subject: 'Broken link',
      description: 'Too short',
      turnstileToken: '',
    });

    expect(parsed.success).toBe(false);
  });
});
