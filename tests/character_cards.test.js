// 设置「角色」页的卡片墙（app/web/character-cards.js）：node --test tests/character_cards.test.js
const test = require('node:test')
const assert = require('node:assert')
const C = require('../app/web/character-cards.js')

const img = id => ({ portrait: `${id}/portrait.webp`, idle: `${id}/idle.webp` })
const chars = [
  { id: 'claude', name: 'Claude', accent: '#e8a33d', images: { idle: 'claude/idle.webp' } },
  { id: 'deepseek', name: 'DeepSeek', accent: '#3b5bb5', images: img('deepseek'), skin: 'deepseek-pajamas',
    skins: [{ id: '', name: '女仆装', images: img('deepseek') }, { id: 'deepseek-pajamas', name: '睡衣', images: { idle: 'deepseek-pajamas/idle.webp' } }] },
  { id: 'mine', name: '小八', images: {} },
]

test('卡片图：portrait 优先，没有用 idle，都没有是 null', () => {
  assert.equal(C.imageOf({ portrait: 'p', idle: 'i' }), 'p')
  assert.equal(C.imageOf({ idle: 'i' }), 'i')
  assert.equal(C.imageOf({}), null)
  assert.equal(C.imageOf(undefined), null)
})

test('衣服卡：每套一张，正在穿的高亮', () => {
  assert.deepStrictEqual(C.outfitCards(chars, 'deepseek'), [
    { id: '', name: '女仆装', image: 'deepseek/portrait.webp', art: true, on: false },
    { id: 'deepseek-pajamas', name: '睡衣', image: 'deepseek-pajamas/idle.webp', art: false, on: true },
  ])
})

test('原版卡用角色自己文件夹的图（穿着皮肤时也一样）', () => {
  assert.equal(C.outfitCards(chars, 'deepseek')[0].image, 'deepseek/portrait.webp')
})

test('没有别的衣服：只有一张「原版」', () => {
  assert.deepStrictEqual(C.outfitCards(chars, 'claude'), [{ id: '', name: '原版', image: 'claude/idle.webp', art: false, on: true }])
})

test('当前角色不在列表里：没有衣服卡', () => {
  assert.deepStrictEqual(C.outfitCards(chars, 'nobody'), [])
})

test('角色卡：原版的图、套数、当前角色高亮，顺序不变', () => {
  assert.deepStrictEqual(C.characterCards(chars, 'deepseek'), [
    { id: 'claude', name: 'Claude', image: 'claude/idle.webp', avatar: false, accent: '#e8a33d', count: 1, on: false },
    { id: 'deepseek', name: 'DeepSeek', image: 'deepseek/portrait.webp', avatar: false, accent: '#3b5bb5', count: 2, on: true },
    { id: 'mine', name: '小八', image: null, avatar: false, accent: '#e0b48a', count: 1, on: false },
  ])
})

test('角色卡优先用探头头像 avatar，没有再退回展示图 / 待机图；衣服卡不用 avatar', () => {
  const list = [{ id: 'gpt', name: 'GPT', images: { avatar: 'gpt/avatar.webp', portrait: 'gpt/portrait.webp', idle: 'gpt/idle.webp' } }]
  assert.equal(C.characterCards(list, 'gpt')[0].image, 'gpt/avatar.webp')
  assert.equal(C.characterCards(list, 'gpt')[0].avatar, true)
  assert.equal(C.characterCards(chars, 'claude')[0].avatar, false)
  assert.equal(C.outfitCards(list, 'gpt')[0].image, 'gpt/portrait.webp')
})

test('衣服卡：有展示图（带背景的整张皮肤图）时 art 为 true，页面铺满整张卡；退回待机图时 false，缩进卡里', () => {
  const [maid, pajamas] = C.outfitCards(chars, 'deepseek')
  assert.equal(maid.art, true)
  assert.equal(pajamas.art, false)
})
