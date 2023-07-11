pragma solidity 0.8.19;

interface ICSRTurnstile {
    error NothingToDistribute();

    struct NFTData {
        uint256 tokenId;
        bool registered;
    }

    function feeRecipient(
        address _smartContract
    ) external view returns (NFTData memory);

    function balances(uint256 _tokenId) external view returns (uint256);

    function currentCounterId() external view returns (uint256);

    function isRegistered(address _smartContract) external view returns (bool);

    function getTokenId(address _smartContract) external view returns (uint256);

    function register(address _recipient) external returns (uint256);

    function withdraw(
        uint256 _tokenId,
        address payable _recipient,
        uint256 _amount
    ) external returns (uint256);

    function distributeFees(uint256 _tokenId) external payable;

    function owner() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
}
