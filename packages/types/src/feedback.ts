import { z } from 'zod';

export const FEEDBACK_CATEGORIES = [
  'bug',
  'feature_request',
  'suggestion',
  'content_correction',
  'other',
] as const;

export type FeedbackCategory = (typeof FEEDBACK_CATEGORIES)[number];

export const feedbackSubmissionSchema = z.object({
  category: z.enum(FEEDBACK_CATEGORIES),
  subject: z
    .string()
    .trim()
    .min(5, 'Subject must be at least 5 characters')
    .max(120, 'Subject must be 120 characters or fewer'),
  description: z
    .string()
    .trim()
    .min(20, 'Description must be at least 20 characters')
    .max(2000, 'Description must be 2000 characters or fewer'),
  replyEmail: z
    .string()
    .trim()
    .email('Please provide a valid email address')
    .max(254)
    .optional()
    .or(z.literal('')),
  turnstileToken: z.string().trim().min(1, 'Verification check is required'),
});

export type FeedbackSubmission = z.infer<typeof feedbackSubmissionSchema>;
