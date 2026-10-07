// 滚动到位时淡入（尊重"减少动态效果"的系统设置）
const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
const items = document.querySelectorAll('.reveal')

if (reduce || !('IntersectionObserver' in window)) {
  items.forEach(el => el.classList.add('on'))
} else {
  const io = new IntersectionObserver((entries) => {
    entries.forEach(e => {
      if (e.isIntersecting) {
        e.target.classList.add('on')
        io.unobserve(e.target)
      }
    })
  }, { rootMargin: '0px 0px -12% 0px', threshold: 0.05 })
  items.forEach(el => io.observe(el))

  // 兜底：万一 IntersectionObserver 没触发（极端环境/被禁用），
  // 也把已经在视口里的内容显示出来 —— 宁可少点动画，不能白屏。
  setTimeout(() => {
    items.forEach(el => {
      if (!el.classList.contains('on') && el.getBoundingClientRect().top < window.innerHeight) {
        el.classList.add('on')
      }
    })
  }, 800)
}
