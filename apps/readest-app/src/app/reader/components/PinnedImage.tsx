import clsx from 'clsx';
import React from 'react';
import { IoPin } from 'react-icons/io5';
import { useTranslation } from '@/hooks/useTranslation';

export interface PinnedImageRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

interface PinnedImageProps {
  src: string;
  alt: string;
  rect: PinnedImageRect;
  onUnpin: () => void;
}

// A locked figure, painted over the page rather than inside it.
//
// The book renders in an iframe that the paginator stretches to hold every
// column of the section at once, so `position: fixed` in there anchors to the
// whole strip and would ride away with page one. Drawing in the host instead
// keeps the figure still while the text turns underneath. The matching strip is
// kept clear on every page by the renderer's `pinned-aspect` attribute, and
// `rect` is the box it reports back via `getPinnedBandRect()`.
const PinnedImage: React.FC<PinnedImageProps> = ({ src, alt, rect, onUnpin }) => {
  const _ = useTranslation();

  return (
    // Taps fall through to the reader so the figure never swallows a page
    // turn; only the unpin badge takes pointer events.
    <div
      className='pointer-events-none absolute z-10'
      style={{ left: rect.left, top: rect.top, width: rect.width, height: rect.height }}
    >
      <img
        src={src}
        alt={alt}
        draggable={false}
        className='h-full w-full select-none object-contain'
      />
      <button
        onClick={onUnpin}
        className={clsx(
          'pointer-events-auto absolute -right-2 -top-2 flex h-6 w-6 cursor-pointer',
          'bg-base-100 text-base-content ring-base-content/15 items-center',
          'justify-center rounded-full shadow-md ring-1 transition-transform hover:scale-110',
        )}
        aria-label={_('Unpin Image')}
        title={_('Unpin Image')}
      >
        <IoPin className='h-3.5 w-3.5' />
      </button>
    </div>
  );
};

export default PinnedImage;
