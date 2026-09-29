// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IERC20Permit is IERC20 {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function getApproved(uint256 tokenId) external view returns (address);
}

contract AirdopMerkleNFTMarket {
    IERC20Permit public immutable paymentToken;
    bytes32 public merkleRoot;
    address public owner;

    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 price;
        bool isActive;
    }

    mapping(uint256 => Listing) public listings;
    uint256 public nextListingId;
    mapping(address => bool) public hasUsedWhitelist;

    event NFTListed(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 price
    );
    event NFTSold(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        address nftContract,
        uint256 tokenId,
        uint256 price
    );
    event NFTListingCancelled(uint256 indexed listingId);
    event WhitelistNFTClaimed(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        address nftContract,
        uint256 tokenId,
        uint256 price
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "AirdopMerkleNFTMarket: not owner");
        _;
    }

    constructor(address _paymentTokenAddress, bytes32 _merkleRoot) {
        require(_paymentTokenAddress != address(0), "AirdopMerkleNFTMarket: zero token");
        paymentToken = IERC20Permit(_paymentTokenAddress);
        merkleRoot = _merkleRoot;
        owner = msg.sender;
    }

    function updateMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }

    function isWhitelisted(address user, bytes32[] calldata proof) public view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(user));
        return _verifyProof(proof, leaf);
    }

    function _verifyProof(bytes32[] calldata proof, bytes32 leaf) internal view returns (bool) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            computedHash = computedHash < proofElement
                ? keccak256(abi.encodePacked(computedHash, proofElement))
                : keccak256(abi.encodePacked(proofElement, computedHash));
        }
        return computedHash == merkleRoot;
    }

    function list(address _nftContract, uint256 _tokenId, uint256 _price) external returns (uint256) {
        require(_price > 0, "AirdopMerkleNFTMarket: price must be greater than zero");
        require(_nftContract != address(0), "AirdopMerkleNFTMarket: zero nft");

        IERC721 nftContract = IERC721(_nftContract);
        address nftOwner = nftContract.ownerOf(_tokenId);
        require(
            nftOwner == msg.sender ||
                nftContract.isApprovedForAll(nftOwner, msg.sender) ||
                nftContract.getApproved(_tokenId) == msg.sender,
            "AirdopMerkleNFTMarket: not owner nor approved"
        );

        uint256 listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: nftOwner,
            nftContract: _nftContract,
            tokenId: _tokenId,
            price: _price,
            isActive: true
        });

        emit NFTListed(listingId, nftOwner, _nftContract, _tokenId, _price);
        return listingId;
    }

    function cancelListing(uint256 _listingId) external {
        Listing storage listing = listings[_listingId];
        require(listing.isActive, "AirdopMerkleNFTMarket: not active");
        require(listing.seller == msg.sender, "AirdopMerkleNFTMarket: not seller");

        listing.isActive = false;
        emit NFTListingCancelled(_listingId);
    }

    function buyNFT(uint256 _listingId) external {
        Listing storage listing = listings[_listingId];
        require(listing.isActive, "AirdopMerkleNFTMarket: not active");

        listing.isActive = false;
        require(
            paymentToken.transferFrom(msg.sender, listing.seller, listing.price),
            "AirdopMerkleNFTMarket: transfer failed"
        );
        IERC721(listing.nftContract).transferFrom(listing.seller, msg.sender, listing.tokenId);

        emit NFTSold(_listingId, msg.sender, listing.seller, listing.nftContract, listing.tokenId, listing.price);
    }

    struct Call {
        address target;
        bytes callData;
    }

    function multicall(Call[] calldata calls) external returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            require(calls[i].target == address(this), "AirdopMerkleNFTMarket: only self delegatecall");

            (bool ok, bytes memory ret) = address(this).delegatecall(calls[i].callData);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            results[i] = ret;
        }
    }

    function permitPrePay(
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(owner == msg.sender, "AirdopMerkleNFTMarket: owner mismatch");
        paymentToken.permit(owner, address(this), value, deadline, v, r, s);
    }

    function claimNFT(uint256 _listingId, bytes32[] calldata merkleProof) external {
        Listing storage listing = listings[_listingId];
        require(listing.isActive, "AirdopMerkleNFTMarket: not active");
        require(isWhitelisted(msg.sender, merkleProof), "AirdopMerkleNFTMarket: not whitelisted");
        require(!hasUsedWhitelist[msg.sender], "AirdopMerkleNFTMarket: discount used");

        uint256 discountedPrice = listing.price / 2;
        require(discountedPrice > 0, "AirdopMerkleNFTMarket: price too low");

        hasUsedWhitelist[msg.sender] = true;
        listing.isActive = false;

        require(
            paymentToken.transferFrom(msg.sender, listing.seller, discountedPrice),
            "AirdopMerkleNFTMarket: transfer failed"
        );
        IERC721(listing.nftContract).transferFrom(listing.seller, msg.sender, listing.tokenId);

        emit WhitelistNFTClaimed(
            _listingId,
            msg.sender,
            listing.seller,
            listing.nftContract,
            listing.tokenId,
            discountedPrice
        );
    }
}
