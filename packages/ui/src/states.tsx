import type { ReactNode } from 'react';
import {
  Alert,
  AlertDescription,
  AlertTitle,
  EmptyState,
  EmptyStateAction,
  EmptyStateDescription,
  EmptyStateTitle,
  Skeleton,
} from './primitives.js';

export interface EmptyStateCardProps {
  title: string;
  description: string;
  action?: ReactNode;
  className?: string;
}

export function EmptyStateCard({
  title,
  description,
  action,
  className = '',
}: EmptyStateCardProps) {
  return (
    <EmptyState
      className={`rounded-2xl border border-[var(--ac-border)] bg-[var(--ac-surface)] p-8 text-center shadow-[var(--ac-shadow-card)] ${className}`}
    >
      <EmptyStateTitle className="text-lg font-semibold text-[var(--ac-ink)]">
        {title}
      </EmptyStateTitle>
      <EmptyStateDescription className="mx-auto mt-2 max-w-prose text-sm text-[var(--ac-ink-muted)]">
        {description}
      </EmptyStateDescription>
      {action ? <EmptyStateAction className="mt-5">{action}</EmptyStateAction> : null}
    </EmptyState>
  );
}

export interface ErrorStateCardProps {
  title: string;
  description: string;
  className?: string;
}

export function ErrorStateCard({
  title,
  description,
  className = '',
}: ErrorStateCardProps) {
  return (
    <Alert
      className={`rounded-2xl border border-[var(--ac-danger)]/30 bg-[var(--ac-danger-soft)] p-5 text-[var(--ac-danger)] ${className}`}
    >
      <AlertTitle className="font-semibold">{title}</AlertTitle>
      <AlertDescription className="mt-1 text-sm">{description}</AlertDescription>
    </Alert>
  );
}

export function SkeletonPlaceCard({ label }: { label: string }) {
  return (
    <div
      aria-label={label}
      className="rounded-2xl border border-[var(--ac-border)] bg-[var(--ac-surface)] p-5 shadow-[var(--ac-shadow-card)]"
    >
      <Skeleton className="h-4 w-24 rounded-full bg-[var(--ac-surface-muted)]" />
      <Skeleton className="mt-3 h-6 w-3/4 rounded-lg bg-[var(--ac-surface-muted)]" />
      <Skeleton className="mt-2 h-4 w-full rounded-lg bg-[var(--ac-surface-muted)]" />
      <Skeleton className="mt-1.5 h-4 w-5/6 rounded-lg bg-[var(--ac-surface-muted)]" />
    </div>
  );
}
