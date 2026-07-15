# Performance

Performance is a functional requirement, not an afterthought. Slow software is broken
software from the user's point of view.

Measure first, then optimize the bottlenecks that measurement reveals.

When applicable:

- Optimize Core Web Vitals.
- Optimize Lighthouse scores.
- Minimize unnecessary rendering.
- Reduce unnecessary allocations.
- Optimize bundle size.
- Prefer lazy loading when beneficial.
- Avoid premature optimization — measure before you tune.
- Never sacrifice maintainability solely to increase benchmark scores.

## Realistic targets

Aim for the highest realistically achievable Google Lighthouse and PageSpeed Insights
scores rather than forcing a perfect score at any cost. A maintainable application that
scores 95 beats a contorted one that scores 100. Chase real user-perceived performance,
not the number.
