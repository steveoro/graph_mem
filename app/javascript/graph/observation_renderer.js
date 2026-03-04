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

export function renderDuplicateWarning(analysis, { deleteBtnId = 'delete-dup-obs-btn' } = {}) {
  if (!analysis.hasDuplicates) return '';

  return `
    <div class="obs-warning-box">
      <p><strong>Found ${analysis.duplicateCount} duplicate observation(s)</strong></p>
      <button id="${deleteBtnId}" class="graph-btn graph-btn--danger">
        Delete All Duplicates
      </button>
    </div>
  `;
}

export function renderObservationCards(observations, analysis) {
  if (observations.length === 0) return '<p>No observations found.</p>';

  return observations
    .slice()
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
    .map(obs => {
      const isDuplicate = analysis.contentCounts[obs.content] > 1;
      return `
        <div class="obs-card ${isDuplicate ? 'obs-card--duplicate' : ''}">
          <div class="obs-card__date">
            ${new Date(obs.created_at).toLocaleString()}
            ${isDuplicate ? '<span class="obs-card__dup-badge">[DUPLICATE]</span>' : ''}
          </div>
          <div>${obs.content}</div>
        </div>
      `;
    }).join('');
}
