import { Item } from "./item";

export function total(items: Item[]): number {
  let sum = 0;
  for (const item of items) {
    sum += item.price;
  }
  return sum;
}

export function count(items: Item[]): number {
  return items.length;
}
