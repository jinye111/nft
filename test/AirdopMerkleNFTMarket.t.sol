// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AirdropToken} from "src/AirdropToken.sol";
import {AirdopMerkleNFTMarket} from "src/AirdopMerkleNFTMarket.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

contract MockNFT is ERC721 {
    uint256 private _nextTokenId;

    constructor() ERC721("MockNFT", "MNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

contract AirdopMerkleNFTMarketTest is Test {
    AirdropToken token;
    MockNFT nft;
    AirdopMerkleNFTMarket market;

    uint256 sellerKey = 0xA11CE;
    uint256 buyerKey = 0xB0B;
    uint256 attackerKey = 0xC0FFEE;

    address seller;
    address buyer;
    address attacker;

    bytes32 merkleRoot;
    bytes32[] buyerProof;
    uint256 tokenId;

    uint256 constant PRICE = 40 ether;

    function setUp() public {
        seller = vm.addr(sellerKey);
        buyer = vm.addr(buyerKey);
        attacker = vm.addr(attackerKey);

        token = new AirdropToken();
        token.transfer(seller, 100 ether);
        token.transfer(buyer, 100 ether);

        nft = new MockNFT();

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(buyer);
        leaves[1] = _leaf(address(0xdead));
        merkleRoot = _buildMerkleRoot(leaves);
        buyerProof = _getProof(leaves, 0);

        market = new AirdopMerkleNFTMarket(address(token), merkleRoot);

        vm.startPrank(seller);
        tokenId = nft.mint(seller);
        nft.setApprovalForAll(address(market), true);
        market.list(address(nft), tokenId, PRICE);
        vm.stopPrank();
    }

    function testClaimWithMulticall() public {
        uint256 discounted = PRICE / 2;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(buyer, discounted, deadline, buyerKey);

        uint256 sellerBefore = token.balanceOf(seller);
        uint256 buyerBefore = token.balanceOf(buyer);

        AirdopMerkleNFTMarket.Call[] memory calls = new AirdopMerkleNFTMarket.Call[](2);
        calls[0] = AirdopMerkleNFTMarket.Call({
            target: address(market),
            callData: abi.encodeCall(AirdopMerkleNFTMarket.permitPrePay, (buyer, discounted, deadline, v, r, s))
        });
        calls[1] = AirdopMerkleNFTMarket.Call({
            target: address(market),
            callData: abi.encodeCall(AirdopMerkleNFTMarket.claimNFT, (0, buyerProof))
        });

        vm.prank(buyer);
        market.multicall(calls);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(token.balanceOf(seller), sellerBefore + discounted);
        assertEq(token.balanceOf(buyer), buyerBefore - discounted);
        assertEq(token.allowance(buyer, address(market)), 0);
    }

    function testRevertsWhenNotWhitelisted() public {
        uint256 discounted = PRICE / 2;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(attacker, discounted, deadline, attackerKey);

        AirdopMerkleNFTMarket.Call[] memory calls = new AirdopMerkleNFTMarket.Call[](2);
        calls[0] = AirdopMerkleNFTMarket.Call({
            target: address(market),
            callData: abi.encodeCall(AirdopMerkleNFTMarket.permitPrePay, (attacker, discounted, deadline, v, r, s))
        });
        calls[1] = AirdopMerkleNFTMarket.Call({
            target: address(market),
            callData: abi.encodeCall(AirdopMerkleNFTMarket.claimNFT, (0, buyerProof))
        });

        vm.prank(attacker);
        vm.expectRevert("AirdopMerkleNFTMarket: not whitelisted");
        market.multicall(calls);
    }

    function _signPermit(address owner, uint256 value, uint256 deadline, uint256 pk)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, address(market), value, token.nonces(owner), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function _leaf(address account) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _buildMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty leaves");
        while (leaves.length > 1) {
            uint256 n = leaves.length;
            bytes32[] memory next = new bytes32[]((n + 1) / 2);
            for (uint256 i = 0; i < n; i += 2) {
                bytes32 a = leaves[i];
                bytes32 b = i + 1 < n ? leaves[i + 1] : leaves[i];
                next[i / 2] = _hashPair(a, b);
            }
            leaves = next;
        }
        return leaves[0];
    }

    function _getProof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        uint256 levels = 0;
        uint256 n = leaves.length;
        while (n > 1) {
            levels++;
            n = (n + 1) / 2;
        }

        proof = new bytes32[](levels);
        uint256 level = 0;
        while (leaves.length > 1) {
            n = leaves.length;
            bytes32[] memory next = new bytes32[]((n + 1) / 2);
            for (uint256 i = 0; i < n; i += 2) {
                bytes32 a = leaves[i];
                bytes32 b = i + 1 < n ? leaves[i + 1] : leaves[i];
                next[i / 2] = _hashPair(a, b);
            }

            uint256 siblingIndex = index ^ 1;
            proof[level] = siblingIndex < n ? leaves[siblingIndex] : leaves[index];

            index = index / 2;
            leaves = next;
            level++;
        }
    }
}
