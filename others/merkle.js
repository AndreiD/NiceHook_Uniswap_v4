const { MerkleTree } = require('merkletreejs');
const keccak256 = require('keccak256');

// List of whitelisted addresses (or any other data)
const whitelist = [
  '0x1111000000000000000000000000000000000000', // alice
  '0x2222000000000000000000000000000000000000', // bob
  '0x33300000000000000000000000000000000000', // charlie
];
//0x99900000000000000000000000000000000000 eve is NOT whitelisted

// Create leaf nodes by hashing the addresses
const leaves = whitelist.map((addr) => keccak256(addr));

// Create the Merkle tree
const merkleTree = new MerkleTree(leaves, keccak256, { sortPairs: true });

// Get the Merkle root
const root = merkleTree.getHexRoot();
console.log('Merkle Root:', root);

let leaf = keccak256('0x1111000000000000000000000000000000000000'); // alice's address
let proof = merkleTree.getHexProof(leaf);
console.log('Merkle Proof for Alice:', proof);

leaf = keccak256('0x2222000000000000000000000000000000000000');
proof = merkleTree.getHexProof(leaf);
console.log('Merkle Proof for Bob:', proof);

leaf = keccak256('0x33300000000000000000000000000000000000');
proof = merkleTree.getHexProof(leaf);
console.log('Merkle Proof for charlie:', proof);

// Merkle Root: 0x94a66a14ffa68ca771258e789aa59ccc467ba0b3244a6b0ef1683f40d96c5c0a
// Merkle Proof for Alice: [
//   '0x0808efdc750a8f87b105314e0110fb89feefe2fc5b5c382863f63cba02005088',
//   '0xf78d5c92338bdd84d36b56e4e74881e5ead16c527f84121d0c77d8951ca62953'
// ]
// Merkle Proof for Bob: [
//   '0xf9e13b59652e0e761ccd12cf71175628053ecd83fcd27f4ccf01d555e6e6756c',
//   '0xf78d5c92338bdd84d36b56e4e74881e5ead16c527f84121d0c77d8951ca62953'
// ]
// Merkle Proof for Bob: [
//   '0x45f6f1b01b3a929605c387398f4919fa4438a40e370c1d40d90f0d9ac78dac14'
// ]
