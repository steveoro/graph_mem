import { el, text, br } from 'lib/dom';

export function analyzeObservations(observations) {
  const contentCounts = {};
  observations.forEach(obs => {
    contentCounts[obs.content] = (contentCounts[obs.content] || 0) + 1;
  });

  const hasDuplicates = Object.values(contentCounts).some(count => count > 1);
  const duplicateCount = Object.values(contentCounts).reduce(
    (sum, count) => sum + (count > 1 ? count - 1 : 0), 0
  );

  return { contentCounts, hasDuplicates, duplicateCount };
}

/** Returns a DOM node (or null when there are no duplicates). */
export function renderDuplicateWarning(analysis, { deleteBtnId = 'delete-dup-obs-btn' } = {}) {
  if (!analysis.hasDuplicates) return null;

  const btn = el('button', { id: deleteBtnId, className: 'graph-btn graph-btn--danger' },
    'Delete All Duplicates');

  const p = el('p', {},
    el('strong', {}, 'Found ' + analysis.duplicateCount + ' duplicate observation(s)'));

  return el('div', { className: 'obs-warning-box' }, p, btn);
}

/** Returns a DOM node containing all observation cards. */
export function renderObservationCards(observations, analysis) {
  if (observations.length === 0) {
    return el('p', {}, 'No observations found.');
  }

  const frag = document.createDocumentFragment();
  observations
    .slice()
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
    .forEach(obs => {
      const isDuplicate = analysis.contentCounts[obs.content] > 1;
      const cardClass = 'obs-card' + (isDuplicate ? ' obs-card--duplicate' : '');

      const dateContent = [text(new Date(obs.created_at).toLocaleString())];
      if (isDuplicate) {
        dateContent.push(el('span', { className: 'obs-card__dup-badge' }, '[DUPLICATE]'));
      }

      const card = el('div', { className: cardClass },
        el('div', { className: 'obs-card__date' }, ...dateContent),
        el('div', {}, text(obs.content))
      );
      frag.appendChild(card);
    });

  return frag;
}
