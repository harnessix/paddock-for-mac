import { Item } from "./item";
import { round } from "./money";

export function total(items: Item[]): number {
  let sum = 0;
  for (const item of items) {
    sum += item.price * item.quantity;
  }
  return round(sum);
}

export function count(items: Item[]): number {
  return items.reduce((n, item) => n + item.quantity, 0);
}

export function isEmpty(items: Item[]): boolean {
  return count(items) === 0;
}

export function names(items: Item[]): string[] {
  return items.map((item) => item.name);
}
