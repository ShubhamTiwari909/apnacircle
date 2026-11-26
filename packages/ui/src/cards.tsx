import {
  Badge,
  Card,
  CardBody,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from './primitives.js';

export interface PlaceCardProps {
  name: string;
  locality: string;
  categoryLabel: string;
  summary: string;
  publicAccessNote: string;
  lastVerifiedAt: string;
  href?: string;
}

export function PlaceCard({
  name,
  locality,
  categoryLabel,
  summary,
  publicAccessNote,
  lastVerifiedAt,
  href,
}: PlaceCardProps) {
  return (
    <Card className="flex h-full flex-col justify-between rounded-2xl border border-[var(--ac-border)] bg-[var(--ac-surface)] p-6 shadow-[var(--ac-shadow-card)] transition-colors hover:border-[var(--ac-border-strong)]">
      <div>
        <CardHeader className="p-0">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <Badge className="rounded-full bg-[var(--ac-accent-soft)] px-3 py-1 text-xs font-medium text-[var(--ac-accent)]">
              {categoryLabel}
            </Badge>
            <span className="text-xs text-[var(--ac-ink-muted)]">{locality}</span>
          </div>
          <CardTitle
            as="h3"
            className="mt-3 text-lg font-semibold leading-snug text-[var(--ac-ink)]"
          >
            {href ? (
              <a
                href={href}
                className="underline-offset-4 hover:text-[var(--ac-accent)] hover:underline"
              >
                {name}
              </a>
            ) : (
              name
            )}
          </CardTitle>
        </CardHeader>
        <CardBody className="mt-2 p-0">
          <CardDescription className="text-sm leading-relaxed text-[var(--ac-ink-muted)]">
            {summary}
          </CardDescription>
        </CardBody>
      </div>
      <CardFooter className="mt-4 flex flex-wrap items-center justify-between gap-2 border-t border-[var(--ac-border)] pt-3 p-0 text-xs text-[var(--ac-ink-muted)]">
        <span>{publicAccessNote}</span>
        <span>{lastVerifiedAt}</span>
      </CardFooter>
    </Card>
  );
}

export interface ArticleCardProps {
  title: string;
  description: string;
  href: string;
  reviewedBy: string;
  lastVerifiedAt: string;
}

export function ArticleCard({
  title,
  description,
  href,
  reviewedBy,
  lastVerifiedAt,
}: ArticleCardProps) {
  return (
    <Card className="flex h-full flex-col justify-between rounded-2xl border border-[var(--ac-border)] bg-[var(--ac-surface)] p-6 shadow-[var(--ac-shadow-card)] transition-colors hover:border-[var(--ac-border-strong)]">
      <div>
        <CardHeader className="p-0">
          <CardTitle
            as="h3"
            className="text-lg font-semibold leading-snug text-[var(--ac-ink)]"
          >
            <a
              href={href}
              className="underline-offset-4 hover:text-[var(--ac-accent)] hover:underline"
            >
              {title}
            </a>
          </CardTitle>
        </CardHeader>
        <CardBody className="mt-2 p-0">
          <CardDescription className="text-sm leading-relaxed text-[var(--ac-ink-muted)]">
            {description}
          </CardDescription>
        </CardBody>
      </div>
      <CardFooter className="mt-4 flex flex-wrap items-center justify-between gap-2 border-t border-[var(--ac-border)] pt-3 p-0 text-xs text-[var(--ac-ink-muted)]">
        <span>{reviewedBy}</span>
        <span>{lastVerifiedAt}</span>
      </CardFooter>
    </Card>
  );
}

export interface EventStatusBadgeProps {
  status: 'upcoming' | 'full' | 'cancelled' | 'completed';
  label: string;
}

export function EventStatusBadge({ status, label }: EventStatusBadgeProps) {
  const tone =
    status === 'cancelled'
      ? 'bg-[var(--ac-danger-soft)] text-[var(--ac-danger)]'
      : status === 'full'
        ? 'bg-[var(--ac-warning-soft)] text-[var(--ac-warning)]'
        : 'bg-[var(--ac-accent-soft)] text-[var(--ac-accent)]';

  return (
    <Badge className={`rounded-full px-3 py-1 text-xs font-medium ${tone}`}>{label}</Badge>
  );
}

export interface MeetupCardProps {
  title: string;
  categoryLabel: string;
  venueName: string;
  locality: string;
  startsAtLabel: string;
  status: 'upcoming' | 'full' | 'cancelled' | 'completed';
  statusLabel: string;
  href: string;
}

export function MeetupCard({
  title,
  categoryLabel,
  venueName,
  locality,
  startsAtLabel,
  status,
  statusLabel,
  href,
}: MeetupCardProps) {
  return (
    <Card className="flex h-full flex-col justify-between rounded-2xl border border-[var(--ac-border)] bg-[var(--ac-surface)] p-6 shadow-[var(--ac-shadow-card)]">
      <div>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <span className="text-xs font-medium text-[var(--ac-warm)]">{categoryLabel}</span>
          <EventStatusBadge status={status} label={statusLabel} />
        </div>
        <CardTitle as="h3" className="mt-3 text-lg font-semibold text-[var(--ac-ink)]">
          <a
            href={href}
            className="underline-offset-4 hover:text-[var(--ac-accent)] hover:underline"
          >
            {title}
          </a>
        </CardTitle>
        <p className="mt-2 text-sm text-[var(--ac-ink-muted)]">
          {venueName} &middot; {locality}
        </p>
      </div>
      <CardFooter className="mt-4 border-t border-[var(--ac-border)] pt-3 p-0 text-xs text-[var(--ac-ink-muted)]">
        {startsAtLabel}
      </CardFooter>
    </Card>
  );
}
